import Testing
@testable import HailCore

/// Releasing the session whenever the policy stops wanting the keepalive, not only while it renders (#354).
@MainActor
@Suite struct BackgroundKeepaliveReleaseTests {
    /// A disconnect while a reply is audible keeps the session for it; the reply ending releases it (#354).
    @Test func aSessionKeptForAnAudibleReplyIsReleasedWhenTheReplyEnds() async {
        let (keepalive, renderer) = Self.connected()
        let player = DuplexPlayer()
        let playback = ReplyPlaybackController(player: player)
        keepalive.follow(playback)
        keepalive.follow(playback)
        keepalive.sceneActive = false
        playback.ingest(duplexEvent())
        #expect(playback.isReplyAudioOutputBusy)
        keepalive.observe(hostReady: false, ambientStreaming: false)
        #expect(renderer.calls == ["start", "stop(keep)"])
        await settle()
        #expect(renderer.calls == ["start", "stop(keep)"])
        player.finish()
        await settle()
        #expect(!playback.isReplyAudioOutputBusy)
        #expect(renderer.calls == ["start", "stop(keep)", "stop(release)"])
        #expect(!keepalive.ownsSession)
    }

    /// Muting a kept reply must not release the session: unmuting never reactivates it (Codex on #362).
    @Test func mutingAKeptReplyKeepsTheSessionUntilTheReplyEnds() async {
        let (keepalive, renderer) = Self.connected()
        let player = DuplexPlayer()
        let playback = ReplyPlaybackController(player: player)
        keepalive.follow(playback)
        keepalive.sceneActive = false
        playback.ingest(duplexEvent())
        keepalive.observe(hostReady: false, ambientStreaming: false)
        #expect(renderer.calls == ["start", "stop(keep)"])
        playback.toggleMute()
        await settle()
        #expect(renderer.calls == ["start", "stop(keep)"])
        playback.toggleMute()
        player.finish()
        await settle()
        #expect(renderer.calls == ["start", "stop(keep)", "stop(release)"])
    }

    /// An interruption stops rendering but leaves the category installed; a policy change still releases it (#354).
    @Test func aPolicyChangeDuringAnInterruptionReleasesTheSession() {
        let (keepalive, renderer) = Self.connected()
        keepalive.sceneActive = false
        renderer.onEvent?(.interrupted)
        #expect(keepalive.ownsSession)
        keepalive.sceneActive = true
        #expect(renderer.calls == ["start", "stop(keep)", "stop(release)"])
        #expect(!keepalive.ownsSession)
        keepalive.sceneActive = false
        #expect(keepalive.isRunning)
        renderer.onEvent?(.interrupted)
        keepalive.observe(hostReady: true, ambientStreaming: true)
        #expect(renderer.calls == ["start", "stop(keep)", "stop(release)", "start", "stop(keep)", "stop(release)"])
    }

    /// Returning to the foreground with a reply audible releases nothing until the reply ends.
    @Test func whileTheReplyIsAudibleAStoppedKeepaliveIsLeftAlone() {
        let (keepalive, renderer) = Self.connected()
        keepalive.isReplyAudible = { true }
        keepalive.sceneActive = false
        keepalive.sceneActive = true
        keepalive.observe(hostReady: false, ambientStreaming: false)
        #expect(renderer.calls == ["start", "stop(keep)"])
        #expect(keepalive.ownsSession)
        keepalive.isReplyAudible = { false }
        keepalive.observe(hostReady: false, ambientStreaming: false)
        #expect(renderer.calls == ["start", "stop(keep)", "stop(release)"])
    }

    /// A start that failed while ambient still held the session retries once ambient releases it (#354).
    @Test func aStartThatFailedUnderAmbientRetriesWhenAmbientReleasesTheSession() {
        let (keepalive, renderer) = Self.connected()
        renderer.failsToStart = true
        keepalive.sceneActive = false
        #expect(!keepalive.isRunning)
        renderer.failsToStart = false
        keepalive.sessionWasReleased()
        #expect(keepalive.isRunning)
        #expect(renderer.calls == ["start", "start"])
    }

    private static func connected() -> (BackgroundKeepalive, FakeKeepaliveRenderer) {
        BackgroundKeepaliveTests.connected()
    }
}
