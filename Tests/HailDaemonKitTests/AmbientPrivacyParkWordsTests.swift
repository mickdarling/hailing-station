#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// #941: a stream restored private keeps privacy's promises past audio: its child's words and requests reach no relay,
/// no agent and no device. Real loopback listener and fake RightyO; all claims, words and PCM synthetic, every wait
/// bounded.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget)
struct AmbientPrivacyParkWordsTests {
    /// A rig whose first connection was made private host-side (no entry announced) and then dropped; the second child
    /// says an ordinary request once its held `started` is released.
    static func privateDropped(speaker: Int = 1, phrase: String? = nil) async throws -> RestoreRig {
        let rig = try await RestoreRig(phrase: phrase, speaker: speaker, holdSpawn: 2)
        let (first, dropped) = try await rig.start()
        let router = rig.router
        #expect(await eventually { router.setDuck(true, connection: dropped, reason: "voice") == 1 },
                "first connection private")
        await rig.drop(first, dropped)
        return rig
    }

    /// (b) The restored child says a request after its private `started`: nothing reaches the agent, the device sees no
    /// heard line, acknowledgement or reply, and no run delivers anything. On main the child is public and dispatches.
    @Test(arguments: [false, true])
    func aRestoredPrivateChildsWordsReachNothing(resume: Bool) async throws {
        let rig = try await Self.privateDropped(speaker: 2, phrase: "archive the project")
        defer { rig.close() }
        let (socket, connection) = try await rig.start(resume: resume,
                                                       capabilities: ["probe", AmbientHeard.capability])
        let router = rig.router
        #expect(router.duckMode(connection: connection))
        try rig.release()
        #expect(await eventually { router.activePipeline?.hearsAudio == true }, "private started confirmed")
        try await barrier(on: socket, step: "nothing told to the device")
        await rig.finish()
        #expect(await rig.env.rig.adapter.contexts.isEmpty, "no request leaves the private child")
        #expect(rig.details("ambient_ended").count == 2)
        #expect(rig.details("ambient_ended").allSatisfy { $0.contains("delivered=0") }, "nothing delivered")
        #expect(rig.details("ambient_acknowledged").isEmpty)
    }
}
#endif
