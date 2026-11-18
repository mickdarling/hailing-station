import Foundation
import HailProtocol
import Network
import Synchronization
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1))) struct SilentSessionUpdateRecipientTests {
    @Test func recipientSwitchDuringPreparationSendsOnlyToNewDeviceExactlyOnce() async throws {
        let rig = try await SilentUpdateRig.make()
        let sessionB = HostSession(host: rig.host.host, authorizer: PersonalTerminalAuthorizer())
        _ = await sessionB.receive(helloFrame(capabilities: [SessionUpdateCard.capability]))
        _ = await sessionB.receive(sessionFrame(payload: .control(.select(targetID: RecipientTestRig.target))))
        let sendsB = Mutex(0)
        let peerB = WebSocketPeer(id: UUID(), connection: NWConnection(host: "127.0.0.1", port: 9, using: .tcp),
            session: sessionB, queue: DispatchQueue(label: "synthetic.silent.b"), helloTimeout: .seconds(5),
            log: { _ in }, onEnd: { _ in }, submitReply: { complete in
                sendsB.withLock { $0 += 1 }; complete(nil)
            })
        await rig.listener.connectSilentTestPeer(peerB)
        let entered = VoiceStopConfirmationHold(), release = VoiceStopConfirmationHold()
        let submission = Task {
            await SessionUpdatePrivacyScope.$beforeEnqueue.withValue({
                entered.release()
                await release.wait()
            }, operation: { await rig.submit() })
        }
        await entered.wait()
        // Both devices still select the target and remain live. Only the current audience changes.
        let ledger = await rig.listener.lastInput
        ledger.record(.init(connection: await sessionB.connectionID, generation: await sessionB.selectionGeneration,
                            at: .now), for: RecipientTestRig.target)
        release.release()
        _ = await submission.value
        #expect(await eventually { await rig.listener.sessionUpdate(.init(action: .status)).held == 0 })
        #expect(rig.sends == 0, "A must never receive a card prepared before the audience switched to B")
        #expect(sendsB.withLock { $0 } == 1)
        await rig.listener.drainSilentSessionUpdates(.recipientChanged)
        #expect(rig.sends == 0 && sendsB.withLock { $0 } == 1)
        await rig.listener.stop()
    }

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
