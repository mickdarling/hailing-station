import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

private struct CancelTestRenderer: SessionUpdateSpeechRendering {
    func render(_ text: String, publish: @Sendable (Data, Bool) async throws -> Void) async throws {}
}

@Suite struct SessionUpdateCancelTests {
    private func receipt(revision: UInt64 = 1) -> SessionUpdateCancellationReceipt {
        let id = UUID()
        let frame = Frame(timestamp: 1, target: "recipient:reply", source: "mac-test",
                          payload: .control(.sessionUpdate(update: id, session: "reply", priority: "action",
                                                          text: "Synthetic private words")))
        return .init(update: id, connection: UUID(), privacyRevision: revision, frame: frame)
    }

    @Test func cancellationCarriesOnlyOriginalIdentityAndRoute() throws {
        let receipt = receipt()
        #expect(receipt.frame.target == "recipient:reply" && receipt.frame.source == "mac-test")
        #expect(receipt.frame.payload == .control(.sessionUpdateCancel(update: receipt.update)))
        let encoded = try #require(String(bytes: try FrameCoding.encode(receipt.frame), encoding: .utf8))
        #expect(!encoded.contains("private words"))
    }

    @Test func delayedPrivacyEntryPreservesNewerPublicAudioIdentity() {
        let fence = SessionUpdateFence(), old = receipt(revision: 1), fresh = receipt(revision: 2)
        #expect(fence.remember(old) && fence.remember(fresh))
        #expect(fence.cancelProactive(olderThan: 2).map(\.update) == [old.update])
        #expect(fence.cancelProactive().map(\.update) == [fresh.update])
        #expect(fence.cancelProactive().isEmpty)
    }

    @Test func rendererCompletionDoesNotForgetDeviceBufferedAudio() async {
        let fence = SessionUpdateFence(), delivered = receipt()
        fence.configure(CancelTestRenderer())
        fence.startSpeech(connection: UUID()) { _ in _ = fence.remember(delivered) }
        await fence.joinSpeech()
        #expect(!fence.speechBusy)
        #expect(fence.cancelProactive().map(\.update) == [delivered.update])
    }

    @Test func scopedCancellationKeepsOtherConnectionsBufferedAudio() {
        let fence = SessionUpdateFence(), first = receipt(), other = receipt()
        #expect(fence.remember(first) && fence.remember(other))
        #expect(fence.cancelProactive(connection: first.connection).map(\.update) == [first.update])
        #expect(fence.cancelProactive(connection: first.connection).map(\.update) == [])
        #expect(fence.cancelProactive().map(\.update) == [other.update])
    }

    @Test func boundedReceiptStoreDeclinesNewSpeechInsteadOfForgettingQueuedAudio() {
        let fence = SessionUpdateFence()
        fence.configure(CancelTestRenderer())
        for _ in 0..<128 { #expect(fence.remember(receipt())) }
        #expect(!fence.remember(receipt()))
        #expect(fence.speechStatus == "receipt_capacity")
        #expect(fence.cancelProactive().count == 128)
        #expect(fence.remember(receipt()))
        #expect(fence.speechStatus == "device_attention_gated")
    }

    @Test func ownerIsRecordedBeforeReceiptAndRevocationGuardsUncooperativeEnqueue() async {
        let fence = SessionUpdateFence(), owner = UUID(), other = UUID()
        let entered = VoiceStopConfirmationHold(), release = VoiceStopConfirmationHold()
        let admitted = Mutex<[Bool]>([])
        fence.configure(CancelTestRenderer())
        fence.startSpeech(connection: owner) { _ in
            entered.release()
            await release.wait()
            admitted.withLock { $0.append(fence.enqueue { true }) }
        }
        await entered.wait()
        #expect(fence.cancelProactive(connection: other).isEmpty)
        #expect(fence.cancelProactive(connection: owner).isEmpty)
        release.release()
        await fence.joinSpeech()
        #expect(admitted.withLock { $0 } == [false])
        fence.startSpeech(connection: owner) { _ in admitted.withLock { $0.append(fence.enqueue { true }) } }
        await fence.joinSpeech()
        #expect(admitted.withLock { $0 } == [false, true])
    }

    @Test func privacyObserverPublishesEntryRevisionsOutsideTheHoldLock() {
        let hold = PrivateReplyHold(), connection = UUID(), entries = Mutex<[UInt64]>([])
        hold.observeEntries { revision in
            #expect(hold.anyHeld, "the callback can read the hold without re-entering a held mutex")
            entries.withLock { $0.append(revision) }
        }
        hold.set(true, connection: connection)
        hold.set(false, connection: connection)
        hold.set(true, connection: connection)
        #expect(entries.withLock { $0 } == [1, 2])
    }

    @Test func quietControlRetractsDeliveredProactiveReceiptsWithoutDroppingCards() async throws {
        let rig = try await SessionUpdateListenerRig.make()
        let fence = await rig.listener.sessionUpdateFence
        #expect(fence.remember(receipt()))
        _ = await rig.listener.sessionUpdate(.init(action: .submit, target: RecipientTestRig.target,
                                                  text: "Synthetic held information"))
        let quiet = await rig.listener.sessionUpdate(.init(action: .quietOn))
        #expect(quiet.quiet && quiet.held == 1)
        #expect(fence.cancelProactive().isEmpty, "quiet already took the delivered cancellation identities")
        await rig.listener.stop()
    }
}
