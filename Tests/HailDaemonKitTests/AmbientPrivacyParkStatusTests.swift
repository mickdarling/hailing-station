#if os(macOS)
import Foundation
import Testing
@testable import HailDaemonKit

/// #941: a status on a restored-private connection answers as on any private connection: as privacy was heard
/// announced before the drop, never more. No clip plays on the restore itself. Synthetic only; every wait bounded.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget)
struct AmbientPrivacyParkStatusTests {
    /// Privacy heard announced before the drop: the restored connection's status answers with the status clip, as on
    /// any private connection, with no new clip or wording.
    @Test func aRestoredConnectionAnswersStatusAsAnyPrivateOne() async throws {
        let rig = try await AmbientPrivacyParkTests.privacyDropped()
        defer { rig.close() }
        #expect(rig.router.state.withLock { $0.parks.values.first?.heard } == true)
        let (socket, connection) = try await rig.start()
        let router = rig.router
        #expect(await eventually { router.activePipeline?.hearsAudio == true }, "restored child confirmed private")
        router.voiceDuck(on: connection, listener: rig.env.listener)(.status)
        #expect(try await rig.confirmation(on: socket) == RestoreRig.status.text)
        #expect(await eventually { rig.details("ambient_duck_confirmed").last?.hasPrefix("status on=true") == true },
                "status answered marker")
        await rig.finish()
    }

    /// Privacy never heard announced (made private host-side): the restored status is silent, as on any private
    /// connection whose privacy was not announced. A park never claims more than the owner heard.
    @Test func aParkNeverHeardAnnouncedKeepsStatusSilent() async throws {
        let rig = try await AmbientPrivacyParkWordsTests.privateDropped()
        defer { rig.close() }
        #expect(rig.router.state.withLock { $0.parks.values.first?.heard } == false)
        let (socket, connection) = try await rig.start()
        let router = rig.router
        try rig.release()
        #expect(await eventually { router.activePipeline?.hearsAudio == true }, "restored child confirmed private")
        router.voiceDuck(on: connection, listener: rig.env.listener)(.status)
        #expect(await eventually {
            rig.details("ambient_duck_confirmed").last == "status on=false confirm=unreported"
        }, "silent status marker")
        try await barrier(on: socket, step: "no status clip")
        await rig.finish()
    }
}
#endif
