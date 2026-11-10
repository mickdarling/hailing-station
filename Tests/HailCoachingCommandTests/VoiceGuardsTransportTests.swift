import Darwin
import Foundation
import Testing
@testable import HailDaemonKit
@testable import haild

@Suite(.serialized) struct VoiceGuardsTransportTests {
    @Test func unreachableSocketFailsDoctorAndStatusKeepsItsExitCode() async throws {
        let rig = try VoiceGuardsCLIRig(setting: .on)
        defer { rig.cleanUp() }
        let live = await liveVoiceGuards(socket: rig.directory.appendingPathComponent("missing.sock"))
        #expect(live == nil)
        let report = PolicyHealthReport(health: healthy, store: rig.file, live: live)
        #expect(!report.healthy)
        #expect(report.voiceGuards == nil)
        let doctor = try await rig.runAsync(["doctor"])
        #expect(doctor.code == 1)
        #expect(doctor.output.contains("FAIL"))
        #expect(doctor.output.contains("unknown (live daemon unavailable or invalid reply)"))
        let status = try await rig.runAsync(["status"])
        #expect(status.code == 0)
        #expect(status.output.contains("voice guards configured: on"))
        #expect(status.output.contains("voice guards effective: unknown"))
        let json = try await rig.runAsync(["status", "--json"])
        #expect(json.code == 0)
        let object = try #require(JSONSerialization.jsonObject(with: Data(json.output.utf8)) as? [String: Any])
        #expect(object["voiceGuards"] is NSNull)
        #expect(object["voiceGuardsEnforced"] is NSNull)
        #expect(object["configuredVoiceGuards"] as? String == "on")
        #expect(object["healthy"] as? Bool == false)
    }

    @Test(arguments: [
        "garbage\n", "{\"delivered\":0}\n",
        "{\"delivered\":0,\"voiceGuards\":{\"value\":\"future\",\"enforced\":false}}\n",
        "{\"delivered\":0,\"voiceGuards\":{\"value\":\"on\"}}\n",
        "{\"delivered\":1,\"voiceGuards\":{\"value\":\"on\",\"enforced\":false}}\n"
    ])
    func malformedOrUnknownReplyFailsDoctor(_ reply: String) async throws {
        try await checkFailure(reply: reply)
    }

    @Test func timeoutFailsDoctor() async throws {
        try await checkFailure(reply: nil)
    }

    @Test func insecureSocketUsesTheExistingClientAuthRefusal() async throws {
        let rig = try VoiceGuardsCLIRig(setting: .on)
        defer { rig.cleanUp() }
        let socket = rig.directory.appendingPathComponent("replies.sock")
        let stub = try VoiceGuardsReplyStub(socket: socket, reply: "{}\n")
        try await stub.start()
        do {
            try #require(chmod(socket.path, 0o666) == 0)
            #expect(await liveVoiceGuards(socket: socket) == nil)
            let ambient = Data(#"{"kind":"ambient","action":"status"}"#.utf8) + Data([10])
            await #expect {
                try await ReplyClient.transact(ambient, socketURL: socket)
            } throws: { error in
                guard case ReplyClientError.invalidSocket(let path) = error else { return false }
                return path == socket.path
            }
            #expect(await stub.requestCount == 0)
            await stub.stop()
        } catch {
            await stub.stop()
            throw error
        }
    }

    private var healthy: HealthReport {
        HealthReport(cli: .init(version: "test", build: nil, hostID: nil), daemon: nil, checks: [])
    }

    private func checkFailure(reply: String?) async throws {
        let rig = try VoiceGuardsCLIRig(setting: .off)
        defer { rig.cleanUp() }
        let stub = try VoiceGuardsReplyStub(socket: rig.directory.appendingPathComponent("replies.sock"), reply: reply)
        try await stub.start()
        do {
            let doctor = try await rig.runAsync(["doctor"])
            #expect(doctor.code == 1)
            #expect(doctor.output.contains("unknown (live daemon unavailable or invalid reply)"))
            #expect(!doctor.output.contains("not enforced by this build"))
            #expect(await stub.requestsAreStatusOnly)
            #expect(await stub.requestCount == 1)
            await stub.stop()
        } catch {
            await stub.stop()
            throw error
        }
    }
}
