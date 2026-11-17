import Foundation
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1))) struct SilentSessionUpdateRecipientTests {
    @Test(arguments: [false, true])
    func cardHeldWithoutRecipientDeliversWhenDeviceConnectsAndStartsListening(_ alreadyConnected: Bool) async throws {
        let fake = try FakeRightyo("/bin/cat > /dev/null")
        defer { fake.cleanUp() }
        let router = AmbientRightyoRouter(configuration: .init(executable: fake.executable, config: fake.config,
            target: RecipientTestRig.target, binding: "reply-binding", allowSynthetic: true,
            timing: .init(eofGrace: 20, termGrace: 20), replyControl: false))
        // This fixture installs neither a peer nor a last-input recipient. Selection alone grants no audience.
        let rig = try await SilentUpdateRig.make(ambient: router, installRecipient: false)
        if alreadyConnected { await rig.listener.connectSilentTestPeer(rig.peer) }
        #expect(await rig.listener.lastInput.latest(for: RecipientTestRig.target) == nil)
        #expect(await rig.listener.updateAudience(for: RecipientTestRig.target).target == nil)
        #expect(router.activeConnection() == nil)
        #expect(await rig.submit().outcome == .held && rig.sends == 0)
        #expect(await rig.listener.sessionUpdate(.init(action: .status)).held == 1)
        if !alreadyConnected { await rig.listener.connectSilentTestPeer(rig.peer) }
        let policy = await rig.host.host.inputPolicyGeneration(for: RecipientTestRig.target)
        router.ambientAudio(.admittedStart(stream: UUID(), connection: rig.connection,
            target: RecipientTestRig.target, selection: await rig.session.selectionGeneration,
            binding: "reply-binding", policy: policy))
        // Join the real owner-change notification; no manual card drain, input, reply or diagnostic event.
        await router.taskProgressChanges.queued({}).value
        #expect(router.activeConnection() == rig.connection)
        #expect(await rig.listener.lastInput.latest(for: RecipientTestRig.target) == nil)
        #expect(await rig.listener.sessionUpdate(.init(action: .status)).held == 0)
        #expect(rig.sends == 1 && rig.drains.contains("trigger=recipient_changed count=1"))
        await rig.listener.stop()
    }
}

extension WebSocketListener {
    func connectSilentTestPeer(_ peer: WebSocketPeer) {
        readyResult = .success(0)
        peers[UUID()] = peer
    }
}
