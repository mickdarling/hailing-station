import Darwin
import Foundation
import Testing
@testable import HailDaemonKit
@testable import haild

/// The policy file and live daemon are separate observations; transport failure never becomes an assumed default.
@Suite(.serialized) struct VoiceGuardsDoctorStatusTests {
    private var healthy: HealthReport {
        HealthReport(cli: .init(version: "test", build: nil, hostID: nil), daemon: nil, checks: [])
    }

    @Test(arguments: LocalVoiceGuardsReport.Value.allCases)
    func doctorAndJSONShowEffectiveSetting(_ value: LocalVoiceGuardsReport.Value) throws {
        let rig = try VoiceGuardsCLIRig(setting: .on)
        defer { rig.cleanUp() }
        let live = LocalVoiceGuardsReport(value: value, enforced: false)
        let report = PolicyHealthReport(health: healthy, store: rig.file, live: live)
        #expect(report.healthy == (value != .unusable))
        let expected = switch value {
        case .on: "on"
        case .off: "off (not enforced by this build)"
        case .unusable: "unusable (running daemon policy failure)"
        }
        #expect(report.checks.first { $0.name == "voice_guards" }?.detail == expected)
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
        #expect(object["voiceGuards"] as? String == value.rawValue)
        #expect(object["configuredVoiceGuards"] as? String == "on")
        #expect(object["voiceGuardsEnforced"] as? Bool == false)
    }

    @Test func enforcedOffUsesVoiceRequestWarning() throws {
        let rig = try VoiceGuardsCLIRig(setting: .off)
        defer { rig.cleanUp() }
        let report = PolicyHealthReport(health: healthy, store: rig.file, live: .init(value: .off, enforced: true))
        #expect(report.healthy)
        #expect(doctorLines(report).contains { $0.contains("voice guard holds are off for voice requests") })
    }

    @Test(arguments: [false, true])
    func unreadableOrMalformedPolicyFailsDoctorAndNeverAssumesASetting(_ unreadable: Bool) async throws {
        let rig = try VoiceGuardsCLIRig(setting: .off)
        defer { rig.cleanUp() }
        if unreadable {
            try FileManager.default.removeItem(at: rig.file.path)
            try FileManager.default.createDirectory(at: rig.file.path, withIntermediateDirectories: false)
        } else {
            try Data(#"{"version":1,"voiceGuards":null}"#.utf8).write(to: rig.file.path)
        }
        let report = PolicyHealthReport(
            health: healthy, store: rig.file, live: .init(value: .unusable, enforced: false)
        )
        #expect(!report.healthy)
        #expect(report.configuredVoiceGuards == nil)
        #expect(report.voiceGuards == .unusable)
        let doctor = try await rig.runAsync(["doctor"])
        #expect(doctor.code == 1)
        #expect(doctor.output.contains("policy unreadable or malformed; voice guards unknown"))
        let status = try await rig.runAsync(["status"])
        #expect(status.code == 9)
        #expect(status.output.contains("policy: UNUSABLE, delivery refused:"))
        #expect(status.output.contains("targets: 1"))
    }

    @Test(arguments: VoiceGuards.allCases, LocalVoiceGuardsReport.Value.allCases)
    func realStatusPreservesOutputAndShowsMismatch(
        _ setting: VoiceGuards, _ value: LocalVoiceGuardsReport.Value
    ) async throws {
        let rig = try VoiceGuardsCLIRig(setting: setting)
        defer { rig.cleanUp() }
        let reply = "{\"delivered\":0,\"voiceGuards\":{\"value\":\"\(value.rawValue)\",\"enforced\":false}}\n"
        let stub = try VoiceGuardsReplyStub(socket: rig.directory.appendingPathComponent("replies.sock"), reply: reply)
        try await stub.start()
        do {
            let status = try await rig.runAsync(["status"])
            #expect(status.code == 0)
            #expect(status.output.contains("policy: \(rig.file.summary), 1 allowed"))
            #expect(status.output.contains("targets: 1"))
            #expect(status.output.contains("voice guards configured: \(setting.rawValue)"))
            let expected = "voice guards effective: \(voiceGuardsDetail(.init(value: value, enforced: false)))"
            #expect(status.output.contains(expected))
            let mismatch = "policy file says \(setting.rawValue); running daemon uses \(value.rawValue); reload pending"
            #expect(status.output.contains(mismatch) == (value.rawValue != setting.rawValue))
            let json = try await rig.runAsync(["status", "--json"])
            #expect(json.code == 0)
            let object = try #require(JSONSerialization.jsonObject(with: Data(json.output.utf8)) as? [String: Any])
            #expect(object["voiceGuards"] as? String == value.rawValue)
            #expect(object["configuredVoiceGuards"] as? String == setting.rawValue)
            let doctor = try await rig.runAsync(["doctor"])
            #expect(doctor.output.contains(voiceGuardsDetail(.init(value: value, enforced: false))))
            #expect(doctor.output.contains(mismatch) == (value.rawValue != setting.rawValue))
            #expect(await stub.requestsAreStatusOnly)
            #expect(await stub.requestCount == 3)
            await stub.stop()
        } catch {
            await stub.stop()
            throw error
        }
    }

    @Test func statusRetainsAdapterListingFailures() async throws {
        let rig = try VoiceGuardsCLIRig(setting: .off)
        defer { rig.cleanUp() }
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: rig.directory.appendingPathComponent("tmux"))
        let status = try await rig.runAsync(["status"])
        #expect(status.code == 0)
        #expect(status.output.contains("policy:"))
        #expect(status.output.contains("targets: 0"))
        #expect(status.output.contains("voice guards configured: off"))
        #expect(status.output.contains("voice guards effective: unknown"))
        #expect(status.error.contains("tmux:"))
    }

    @Test func realSendStillRequiresConfirmationWhenOff() async throws {
        let rig = try VoiceGuardsCLIRig(setting: .off)
        defer { rig.cleanUp() }
        let result = try await rig.runAsync(["send", "tmux:a", "guarded-token"])
        #expect(result.code == 8)
        #expect(result.error.contains("guarded: synthetic"))
        #expect(result.error.contains("confirmation needed; run from a terminal to read back"))
        #expect(!FileManager.default.fileExists(atPath: rig.directory.appendingPathComponent("delivered").path))
    }
}

struct VoiceGuardsCLIRig: Sendable {
    let directory: URL
    let file: PolicyFile
    /// One fixture subprocess at a time, with blocking waits off Swift's cooperative executor.
    private static let processQueue = DispatchQueue(label: "hail.voice-cli-test", qos: .utility)

    init(setting: VoiceGuards) throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hail-voice-cli-\(UUID().uuidString.prefix(8))")
        file = PolicyFile(directory: directory)
        var policy = Policy(
            guardPatterns: [GuardPattern(name: "synthetic", regex: "guarded-token")], voiceGuards: setting
        )
        try policy.allow("tmux:a", binding: "$1@1/%1:1", tier: .open)
        try file.save(policy)
        let tmux = directory.appendingPathComponent("tmux")
        let script = """
        #!/bin/sh
        if [ "$1" = list-sessions ]; then
          printf '%s\\n' '$1|1|%1|1|a'
        else
          touch "$HAIL_CONFIG_DIR/delivered"
          exit 1
        fi
        """
        try Data(script.utf8).write(to: tmux)
        try #require(chmod(tmux.path, 0o700) == 0)
    }

    func cleanUp() { try? FileManager.default.removeItem(at: directory) }

    struct Result: Sendable {
        let code: Int32
        let output: String
        let error: String
    }

    func runAsync(_ arguments: [String]) async throws -> Result {
        try await withCheckedThrowingContinuation { continuation in
            Self.processQueue.async {
                continuation.resume(with: Swift.Result { try run(arguments) })
            }
        }
    }

    func run(_ arguments: [String]) throws -> Result {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent(".build/debug/haild")
        process.arguments = arguments
        process.environment = ["PATH": "/usr/bin:/bin", "HAIL_CONFIG_DIR": directory.path,
                               "HAIL_TMUX": directory.appendingPathComponent("tmux").path]
        let output = Pipe(), error = Pipe()
        process.standardOutput = output
        process.standardError = error
        process.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()
        let finished = exited.wait(timeout: .now() + .seconds(30)) == .success
        if !finished {
            kill(process.processIdentifier, SIGKILL)
            let stopped = exited.wait(timeout: .now() + .seconds(5)) == .success
            try #require(stopped)
        }
        try #require(finished, "CLI process timed out")
        return Result(
            code: process.terminationStatus,
            output: String(data: output.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "",
            error: String(data: error.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        )
    }
}
