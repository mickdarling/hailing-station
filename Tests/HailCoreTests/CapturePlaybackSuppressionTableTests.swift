import Foundation
@testable import HailCore
import HailProtocol
import Testing

/// #763 review: the per-player ledger table never keeps a closed scene's player alive.
@MainActor
@Suite struct CapturePlaybackSuppressionTableTests {
    @Test func aPlayersLedgerIsRemovedOnceItsLastHoldEnds() {
        let playback = ReplyPlaybackController(player: TablePlayer())
        let owner = UUID()
        CapturePlaybackSuppression.liveness[owner] = { true }
        CapturePlaybackSuppression.begin(owner, using: playback)
        #expect(CapturePlaybackSuppression.hasLedger(for: playback))
        CapturePlaybackSuppression.end(owner, using: playback, resuming: true)
        #expect(!CapturePlaybackSuppression.hasLedger(for: playback))
        #expect(!playback.isCaptureSuppressed)
    }

    @Test func aHealThatEmptiesTheLedgerRemovesIt() {
        let playback = ReplyPlaybackController(player: TablePlayer())
        CapturePlaybackSuppression.begin(UUID(), using: playback) // No liveness registered: never live.
        CapturePlaybackSuppression.reconcile(using: playback)
        #expect(!CapturePlaybackSuppression.hasLedger(for: playback))
        #expect(!playback.isCaptureSuppressed)
    }

    /// A ledger that still has a live owner is never removed: removing it would leave replies held with nothing able
    /// to release them.
    @Test func aLedgerWithALiveOwnerIsKeptUntilThatOwnerEnds() {
        let playback = ReplyPlaybackController(player: TablePlayer())
        let live = UUID()
        CapturePlaybackSuppression.liveness[live] = { true }
        CapturePlaybackSuppression.begin(live, using: playback)
        CapturePlaybackSuppression.begin(UUID(), using: playback) // No liveness: dead.
        CapturePlaybackSuppression.reconcile(using: playback)
        #expect(CapturePlaybackSuppression.hasLedger(for: playback))
        #expect(playback.isCaptureSuppressed)
        CapturePlaybackSuppression.end(live, using: playback, resuming: true)
        #expect(!CapturePlaybackSuppression.hasLedger(for: playback))
        #expect(!playback.isCaptureSuppressed)
    }

    /// A heal's count goes back to the scene that asked, which logs it; nothing is stored globally (#763 review).
    @Test func eachCallReturnsTheHoldsItsHealDropped() {
        let playback = ReplyPlaybackController(player: TablePlayer())
        let live = UUID()
        CapturePlaybackSuppression.liveness[live] = { true }
        CapturePlaybackSuppression.begin(live, using: playback)
        CapturePlaybackSuppression.begin(UUID(), using: playback) // Dead.
        CapturePlaybackSuppression.begin(UUID(), using: playback) // Dead.
        #expect(CapturePlaybackSuppression.reconcile(using: playback) == 2)
        #expect(CapturePlaybackSuppression.releaseCompleted(using: playback) == 0)
        #expect(CapturePlaybackSuppression.end(live, using: playback, resuming: true) == 0)
        #expect(CapturePlaybackSuppression.reconcile(using: playback) == 0)
    }

    @Test func sceneActivationWithNoHoldCreatesNoLedger() {
        let playback = ReplyPlaybackController(player: TablePlayer())
        CapturePlaybackSuppression.releaseCompleted(using: playback)
        CapturePlaybackSuppression.reconcile(using: playback)
        #expect(!CapturePlaybackSuppression.hasLedger(for: playback))
    }
}

@MainActor
private final class TablePlayer: ReplyAudioPlaying {
    func schedule(_: AudioPayload, onPlayed _: (@MainActor @Sendable () -> Void)?) {}
    func cancel() {}
    func pause() {}
    func resume() {}
    func setMuted(_: Bool) {}
    func replaceQueue(with _: [AudioPayload], onPlayed _: (@MainActor @Sendable () -> Void)?) {}
}
