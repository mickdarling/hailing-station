import Foundation
import Testing
@testable import HailCore

/// The background keepalive (#352): while a host is connected and ambient listening is off, leaving the foreground
/// renders silence so iOS keeps the station running; the foreground, a disconnect or ambient listening ends it.
@MainActor
@Suite struct BackgroundKeepaliveTests {
    @Test func policyRunsOnlyInTheBackgroundWhileConnectedWithoutAmbient() {
        #expect(BackgroundKeepalivePolicy.shouldRun(sceneActive: false, hostReady: true, ambientStreaming: false))
        #expect(!BackgroundKeepalivePolicy.shouldRun(sceneActive: true, hostReady: true, ambientStreaming: false))
        #expect(!BackgroundKeepalivePolicy.shouldRun(sceneActive: false, hostReady: false, ambientStreaming: false))
        #expect(!BackgroundKeepalivePolicy.shouldRun(sceneActive: false, hostReady: true, ambientStreaming: true))
    }

    @Test func leavingTheForegroundWhileConnectedStartsItAndReturningReleasesTheSession() {
        let (keepalive, renderer) = Self.connected()
        keepalive.sceneActive = false
        #expect(keepalive.isRunning)
        #expect(renderer.calls == ["start"])
        keepalive.sceneActive = true
        #expect(!keepalive.isRunning)
        #expect(renderer.calls == ["start", "stop(release)"])
    }

    @Test func withoutAConnectionItNeverStarts() {
        let renderer = FakeKeepaliveRenderer()
        let keepalive = BackgroundKeepalive(renderer: renderer)
        keepalive.sceneActive = false
        #expect(renderer.calls.isEmpty)
    }

    @Test func aDisconnectInTheBackgroundStopsItAndAReconnectStartsItAgain() {
        let (keepalive, renderer) = Self.connected()
        keepalive.sceneActive = false
        keepalive.observe(hostReady: false, ambientStreaming: false)
        #expect(!keepalive.isRunning)
        keepalive.observe(hostReady: true, ambientStreaming: false)
        #expect(renderer.calls == ["start", "stop(release)", "start"])
    }

    /// Ambient listening keeps the app alive itself (#282); when it ends in the background the keepalive takes over.
    @Test func ambientStreamingKeepsItOffAndItsEndHandsOver() {
        let (keepalive, renderer) = Self.connected()
        keepalive.observe(hostReady: true, ambientStreaming: true)
        keepalive.sceneActive = false
        #expect(renderer.calls.isEmpty)
        keepalive.observe(hostReady: true, ambientStreaming: false)
        #expect(renderer.calls == ["start"])
        keepalive.observe(hostReady: true, ambientStreaming: true)
        #expect(renderer.calls == ["start", "stop(release)"])
    }

    @Test func anAudibleReplyKeepsTheSessionWhenItStops() {
        let (keepalive, renderer) = Self.connected()
        keepalive.isReplyAudible = { true }
        keepalive.sceneActive = false
        keepalive.sceneActive = true
        #expect(renderer.calls == ["start", "stop(keep)"])
    }

    /// Ambient listening releasing the session as it ends must not leave the app without a renderer.
    @Test func aSessionReleasedUnderItRestartsRendering() {
        let (keepalive, renderer) = Self.connected()
        keepalive.sceneActive = false
        keepalive.sessionWasReleased()
        #expect(keepalive.isRunning)
        #expect(renderer.calls == ["start", "stop(keep)", "start"])
        keepalive.sceneActive = true
        keepalive.sessionWasReleased()
        #expect(renderer.calls == ["start", "stop(keep)", "start", "stop(release)"])
    }

    @Test func anInterruptionHoldsItUntilTheSystemSaysToResume() {
        let (keepalive, renderer) = Self.connected()
        keepalive.sceneActive = false
        renderer.onEvent?(.interrupted)
        #expect(!keepalive.isRunning)
        renderer.onEvent?(.interruptionEnded(shouldResume: false))
        keepalive.observe(hostReady: true, ambientStreaming: false)
        #expect(renderer.calls == ["start", "stop(keep)"])
        renderer.onEvent?(.interruptionEnded(shouldResume: true))
        #expect(keepalive.isRunning)
        #expect(renderer.calls == ["start", "stop(keep)", "start"])
    }

    @Test func aFailedStartWaitsForTheNextBackgroundRatherThanRetrying() {
        let (keepalive, renderer) = Self.connected()
        renderer.failsToStart = true
        keepalive.sceneActive = false
        keepalive.observe(hostReady: true, ambientStreaming: false)
        #expect(!keepalive.isRunning)
        #expect(renderer.calls == ["start"])
        renderer.failsToStart = false
        keepalive.sceneActive = true
        keepalive.sceneActive = false
        #expect(keepalive.isRunning)
        #expect(renderer.calls == ["start", "start"])
    }

    /// A store with no ready host counts as disconnected; changes reach the keepalive without a view.
    @Test func itFollowsTheStoreWithoutAView() async {
        let store = HostConnectionStore()
        let (keepalive, renderer) = Self.connected()
        keepalive.sceneActive = false
        keepalive.follow(store)
        #expect(renderer.calls == ["start", "stop(release)"])
        store.ambientStreaming = true
        for _ in 0..<20 where !keepalive.ambientStreaming { await Task.yield() }
        #expect(keepalive.ambientStreaming)
    }

    static func connected() -> (BackgroundKeepalive, FakeKeepaliveRenderer) {
        let renderer = FakeKeepaliveRenderer()
        let keepalive = BackgroundKeepalive(renderer: renderer)
        keepalive.observe(hostReady: true, ambientStreaming: false)
        return (keepalive, renderer)
    }
}

@MainActor
final class FakeKeepaliveRenderer: BackgroundKeepaliveRendering {
    var onEvent: (@MainActor (BackgroundKeepaliveEvent) -> Void)?
    var calls: [String] = []
    var failsToStart = false

    func start() throws {
        calls.append("start")
        if failsToStart { throw ReplyAudioPlayerError.invalidBuffer }
    }

    func stop(releasingSession: Bool) {
        calls.append(releasingSession ? "stop(release)" : "stop(keep)")
    }
}
