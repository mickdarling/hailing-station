import Foundation
import HailCore
import HailProtocol
import Testing

/// #760: reply audio stayed held after tap to talk ended, because a capture owner with no live capture kept capture
/// suppression. Owners are views' capture IDs; `live` stands in for each view's starting, recording, finalizing or
/// interrupting state.
@MainActor
@Suite struct CaptureSuppressionLedgerTests {
    /// The device timeline: on returning to the foreground, the torn-down station view's forced teardown took
    /// suppression with no capture (the first `tap_to_talk_start`) and finished only after the scene-active release
    /// had run. The remounted view's real tap to talk then began and ended; replies must play after it.
    @Test func replyPlaysAfterTapToTalkEndsDespiteTornDownViewsHold() {
        let rig = LedgerRig()
        let tornDown = UUID()
        let remounted = UUID()
        rig.ledger.begin(tornDown)
        rig.ledger.releaseCompleted()
        rig.ledger.markCleanupComplete(tornDown)

        rig.live.insert(remounted)
        rig.ledger.begin(remounted)
        rig.playback.ingest(ledgerEvent())
        #expect(rig.player.scheduled.isEmpty)
        rig.live.remove(remounted)
        let stale = rig.ledger.end(remounted, resuming: true)

        #expect(stale == [tornDown])
        #expect(rig.ledger.owners.isEmpty)
        #expect(!rig.playback.isCaptureSuppressed)
        #expect(rig.player.scheduled.count == 1)
        #expect(rig.playback.statusForControls == "Playing")
    }

    /// Whatever path leaked it, an owner with no live capture is dropped when a reply arrives and the app reconciles.
    @Test func reconcileReleasesLeakedOwnerSoArrivingReplyPlays() {
        let rig = LedgerRig()
        let leaked = UUID()
        rig.ledger.begin(leaked)
        rig.playback.ingest(ledgerEvent())
        #expect(rig.playback.statusForControls == "Paused while listening")

        #expect(rig.ledger.reconcile() == [leaked])
        #expect(!rig.playback.isCaptureSuppressed)
        #expect(rig.player.scheduled.count == 1)
        #expect(rig.ledger.reconcile().isEmpty)
    }

    /// Half duplex stands: a capture that is still live is never healed away, and the leaked owner beside it goes.
    @Test func reconcileKeepsLiveCaptureHolding() {
        let rig = LedgerRig()
        let leaked = UUID()
        let talking = UUID()
        rig.ledger.begin(leaked)
        rig.live.insert(talking)
        rig.ledger.begin(talking)
        rig.playback.ingest(ledgerEvent())

        #expect(rig.ledger.reconcile() == [leaked])
        #expect(rig.ledger.owners == [talking])
        #expect(rig.playback.isCaptureSuppressed)
        #expect(rig.player.scheduled.isEmpty)
        #expect(rig.ledger.releaseCompleted().isEmpty)
        #expect(rig.playback.isCaptureSuppressed)
    }

    /// The owner's explicit pause survives the heal.
    @Test func reconcileKeepsExplicitPause() {
        let rig = LedgerRig()
        rig.ledger.begin(UUID())
        rig.playback.ingest(ledgerEvent())
        rig.playback.togglePause()

        #expect(rig.ledger.reconcile().count == 1)
        #expect(rig.playback.isPaused)
        #expect(rig.player.scheduled.isEmpty)
        #expect(!rig.playback.isCaptureSuppressed)
    }

    /// A completed teardown is released on scene activation, but not while that owner has begun capturing again.
    @Test func releaseCompletedSkipsOwnerCapturingAgain() {
        let rig = LedgerRig()
        let owner = UUID()
        rig.ledger.begin(owner)
        rig.ledger.markCleanupComplete(owner)
        rig.live.insert(owner)

        #expect(rig.ledger.releaseCompleted().isEmpty)
        #expect(rig.playback.isCaptureSuppressed)

        rig.live.remove(owner)
        #expect(rig.ledger.releaseCompleted() == [owner])
        #expect(!rig.playback.isCaptureSuppressed)
    }

    /// Ending one owner while another real capture is live keeps replies held until that one ends too.
    @Test func endingOneOwnerKeepsAnotherLiveCaptureHolding() {
        let rig = LedgerRig()
        let first = UUID()
        let second = UUID()
        rig.live = [first, second]
        rig.ledger.begin(first)
        rig.ledger.begin(second)
        rig.live.remove(first)

        #expect(rig.ledger.end(first, resuming: true).isEmpty)
        #expect(rig.playback.isCaptureSuppressed)
        rig.live.remove(second)
        rig.ledger.end(second, resuming: true)
        #expect(!rig.playback.isCaptureSuppressed)
    }
}

@MainActor
private final class LedgerRig {
    let player = LedgerPlayer()
    let playback: ReplyPlaybackController
    let ledger: CaptureSuppressionLedger
    private let owners: LiveOwners
    var live: Set<UUID> {
        get { owners.ids }
        set { owners.ids = newValue }
    }

    init() {
        let playback = ReplyPlaybackController(player: player)
        let owners = LiveOwners()
        self.owners = owners
        self.playback = playback
        ledger = CaptureSuppressionLedger(playback: playback) { owners.ids.contains($0) }
    }
}

@MainActor
private final class LiveOwners {
    var ids: Set<UUID> = []
}

@MainActor
private final class LedgerPlayer: ReplyAudioPlaying {
    var scheduled: [AudioPayload] = []

    func schedule(_ payload: AudioPayload, onPlayed _: (@MainActor @Sendable () -> Void)?) {
        scheduled.append(payload)
    }
    func cancel() {}
    func pause() {}
    func resume() {}
    func setMuted(_: Bool) {}
    func replaceQueue(with _: [AudioPayload], onPlayed _: (@MainActor @Sendable () -> Void)?) {}
}

private func ledgerEvent() -> HostReplyEvent {
    let reply = ReplyDescriptor(id: UUID(), hostID: "main-mac", targetID: "tmux:codex", audioStreamID: UUID())
    let audio = AudioPayload(
        codec: .pcm16, sampleRate: 24_000, channels: 1, sequence: 0,
        streamID: reply.audioStreamID, isFinal: true, bytes: Data([1, 0]), reply: reply
    )
    return HostReplyEvent(
        endpointID: "main",
        frame: Frame(timestamp: 0, target: reply.targetID, source: reply.hostID, payload: .audio(audio))
    )
}
