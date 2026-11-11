import Foundation
import Testing
@testable import HailDaemonKit
@testable import haild

@Suite(.serialized) struct VoiceGuardsEnforcedStatusTests {
    @Test func enforcingDaemonShowsOffWordingInStatusAndDoctor() async throws {
        let rig = try VoiceGuardsCLIRig(setting: .off)
        defer { rig.cleanUp() }
        let reply = "{\"delivered\":0,\"voiceGuards\":{\"value\":\"off\",\"enforced\":true}}\n"
        let stub = try VoiceGuardsReplyStub(socket: rig.directory.appendingPathComponent("replies.sock"), reply: reply)
        try await stub.start()
        do {
            for command in ["status", "doctor"] {
                let result = try await rig.runAsync([command])
                #expect(result.output.contains("voice guard holds are off for voice requests"))
            }
            let json = try await rig.runAsync(["status", "--json"])
            let object = try #require(JSONSerialization.jsonObject(with: Data(json.output.utf8)) as? [String: Any])
            #expect(object["voiceGuardsEnforced"] as? Bool == true)
            await stub.stop()
        } catch {
            await stub.stop()
            throw error
        }
    }
}
