import Foundation
import HailProtocol
import Network
import Synchronization
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1))) struct SilentSessionUpdateCancellationTests {
    @Test func abandonedCardMustNotBeEnqueuedAgainByPendingDrain() async throws {
        let completion = SilentUpdateCompletion()
        let rig = try await SilentUpdateRig.make(send: { completion.send($0) })
        let first = Task { await rig.submit() }
        await completion.entered.wait()
        #expect(await rig.submit().outcome == .held)
        first.cancel()
        #expect(await first.value.outcome == .held)
        #expect(await eventually {
            let delivering = await rig.listener.sessionUpdatesDelivering
            return rig.sends >= 2 && !delivering
        })
        #expect(rig.sends == 2, "a pending drain must skip the enqueued first card")
        completion.completeFirst()
        #expect(await eventually { await rig.listener.sessionUpdate(.init(action: .status)).held == 0 })
        #expect(await rig.peer.isLive)
        #expect(rig.sends == 2, "two updates must have two transport enqueues, including late success")
        await rig.listener.stop()
    }

    @Test func cancellationAfterEnqueueRetainsOwnershipUntilSuccess() async throws {
        let completion = SilentUpdateCompletion()
        let rig = try await SilentUpdateRig.make(send: { completion.send($0) })
        let submission = Task { await rig.submit() }
        await completion.entered.wait()
        submission.cancel()
        #expect(await submission.value.outcome == .held)
        await rig.listener.drainSilentSessionUpdates(.immediate)
        #expect(rig.sends == 1)
        completion.completeFirst()
        #expect(await eventually { await rig.listener.sessionUpdate(.init(action: .status)).held == 0 })
        await rig.listener.drainSilentSessionUpdates(.immediate)
        #expect(rig.sends == 1)
        #expect(await rig.peer.isLive)
        await rig.listener.stop()
    }

    @Test func cancellationBeforeEnqueueLeavesEachCardForTheDrainOnce() async throws {
        let rig = try await SilentUpdateRig.make()
        let entered = VoiceStopConfirmationHold(), release = VoiceStopConfirmationHold()
        let submission = Task {
            await SessionUpdatePrivacyScope.$beforeEnqueue.withValue({
                entered.release()
                await release.wait()
            }, operation: { await rig.submit() })
        }
        await entered.wait()
        #expect(await rig.submit().outcome == .held)
        submission.cancel()
        release.release()
        #expect(await submission.value.outcome == .held)
        #expect(await eventually { await rig.listener.sessionUpdate(.init(action: .status)).held == 0 })
        #expect(rig.sends == 2)
        await rig.listener.drainSilentSessionUpdates(.immediate)
        #expect(rig.sends == 2)
        await rig.listener.stop()
    }

    @Test(arguments: [false, true], [false, true])
    func retiredSendRetainsCardForTheNextRecipient(lateFailure: Bool, cancelCaller: Bool) async throws {
        let completion = SilentUpdateCompletion()
        let rig = try await SilentUpdateRig.make(send: { completion.send($0) })
        let submission = Task { await rig.submit() }
        await completion.entered.wait()
        if cancelCaller {
            submission.cancel()
            _ = await submission.value
        }
        await rig.peer.finish(reason: "synthetic retirement during send")
        let replacementSends = Mutex(0)
        let session = HostSession(host: rig.host.host, authorizer: PersonalTerminalAuthorizer())
        _ = await session.receive(helloFrame(capabilities: [SessionUpdateCard.capability]))
        _ = await session.receive(sessionFrame(payload: .control(.select(targetID: RecipientTestRig.target))))
        let peer = WebSocketPeer(id: UUID(), connection: NWConnection(host: "127.0.0.1", port: 9, using: .tcp),
            session: session, queue: DispatchQueue(label: "synthetic.replacement"), helloTimeout: .seconds(5),
            log: { _ in }, onEnd: { _ in }, submitReply: { complete in
                replacementSends.withLock { $0 += 1 }; complete(nil)
            })
        await rig.listener.installSessionUpdateTestPeer(peer, connectionID: session.connectionID,
                                                       generation: session.selectionGeneration)
        // A retired peer's late completion must neither consume the retained card nor a newer attempt.
        completion.completeFirst(lateFailure ? NWError.posix(.ECONNRESET) : nil)
        _ = await submission.value
        #expect(await rig.listener.sessionUpdate(.init(action: .status)).held == 1)
        await rig.listener.drainSilentSessionUpdates(.recipientChanged)
        #expect(await rig.listener.sessionUpdate(.init(action: .status)).held == 0)
        await rig.listener.drainSilentSessionUpdates(.immediate)
        #expect(rig.sends == 1 && replacementSends.withLock { $0 } == 1)
        await rig.listener.stop()
    }
}

/// Holds only the first synthetic Network completion; every subsequent enqueue succeeds synchronously.
private final class SilentUpdateCompletion: Sendable {
    let entered = VoiceStopConfirmationHold()
    private let first = Mutex<(@Sendable (NWError?) -> Void)?>(nil)
    private let started = Mutex(false)
    func send(_ completion: @escaping @Sendable (NWError?) -> Void) {
        let initial = started.withLock { started in
            if started { return false }
            started = true
            return true
        }
        if initial {
            first.withLock { $0 = completion }
            entered.release()
        } else { completion(nil) }
    }
    func completeFirst(_ error: NWError? = nil) {
        let callback = first.withLock { first in
            let callback = first
            first = nil
            return callback
        }
        callback?(error)
    }
}
