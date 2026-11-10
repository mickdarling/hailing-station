import Darwin
import Foundation
import Testing
@testable import HailDaemonKit
@testable import haild

/// Owner policy visibility uses the real loader; CLI checks use a synthetic target and no running daemon.
@Suite(.serialized) struct VoiceGuardsDoctorStatusTests {
    private var healthy: HealthReport {
        HealthReport(cli: .init(version: "test", build: nil, hostID: nil), daemon: nil, checks: [])
    }

    @Test(arguments: VoiceGuards.allCases)
    func doctorAndJSONShowConfiguredSetting(_ setting: VoiceGuards) throws {
        let rig = try VoiceGuardsCLIRig(setting: setting)
        defer { rig.cleanUp() }
        let report = PolicyHealthReport(health: healthy, store: rig.file)
        #expect(report.healthy)
        if setting == .off {
            #expect(doctorLines(report) == ["WARN  voice_guards  off in policy (not enforced by this build)"])
        } else {
            #expect(doctorLines(report).isEmpty)
        }
        let data = try JSONEncoder.hailStatus.encode(report)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["voiceGuards"] as? String == setting.rawValue)
        #expect(object["voiceGuardsEnforced"] as? Bool == false)
        #expect(object["healthy"] as? Bool == true)
    }

    @Test(arguments: [false, true])
    func unreadableOrMalformedPolicyFailsDoctorAndNeverAssumesASetting(_ unreadable: Bool) throws {
        let rig = try VoiceGuardsCLIRig(setting: .off)
        defer { rig.cleanUp() }
        if unreadable {
            try FileManager.default.removeItem(at: rig.file.path)
            try FileManager.default.createDirectory(at: rig.file.path, withIntermediateDirectories: false)
        } else {
            try Data(#"{"version":1,"voiceGuards":null}"#.utf8).write(to: rig.file.path)
        }
        let report = PolicyHealthReport(health: healthy, store: rig.file)
        #expect(!report.healthy)
        #expect(report.voiceGuards == nil)
        #expect(report.checks.last?.name == "policy")
        #expect(report.checks.last?.outcome == .fail)
        let object = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(report)) as? [String: Any])
        #expect(object["voiceGuards"] is NSNull)
        #expect(object["healthy"] as? Bool == false)
        let doctor = try rig.run(["doctor"])
        #expect(doctor.code == 1)
        #expect(doctor.output.contains("policy unreadable or malformed; voice guards unknown"))
    }

    @Test(arguments: VoiceGuards.allCases)
    func realStatusAndJSONIncludeTheSetting(_ setting: VoiceGuards) throws {
        let rig = try VoiceGuardsCLIRig(setting: setting)
        defer { rig.cleanUp() }
        let status = try rig.run(["status"])
        #expect(status.code == 0)
        let expected = setting == .on ? "voice guards: on" : "voice guards: off (off not enforced by this build)"
        #expect(status.output.split(separator: "\n").contains(Substring(expected)))
        let json = try rig.run(["status", "--json"])
        #expect(json.code == 0)
        let object = try #require(JSONSerialization.jsonObject(with: Data(json.output.utf8)) as? [String: Any])
        #expect(object["voiceGuards"] as? String == setting.rawValue)
        #expect(object["voiceGuardsEnforced"] as? Bool == false)
        let doctor = try rig.run(["doctor"])
        #expect(doctor.output.contains("voice_guards") == (setting == .off))
        if setting == .off { #expect(doctor.output.contains("off in policy (not enforced by this build)")) }
    }

    @Test func realSendStillRequiresConfirmationWhenOff() throws {
        let rig = try VoiceGuardsCLIRig(setting: .off)
        defer { rig.cleanUp() }
        let result = try rig.run(["send", "tmux:a", "guarded-token"])
        #expect(result.code == 8)
        #expect(result.error.contains("guarded: synthetic"))
        #expect(result.error.contains("confirmation needed; run from a terminal to read back"))
        #expect(!FileManager.default.fileExists(atPath: rig.directory.appendingPathComponent("delivered").path))
    }
}

private struct VoiceGuardsCLIRig {
    let directory: URL
    let file: PolicyFile

    init(setting: VoiceGuards) throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("hail-voice-cli-\(UUID())")
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

    struct Result {
        let code: Int32
        let output: String
        let error: String
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
        let finished = exited.wait(timeout: .now() + .seconds(15)) == .success
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
