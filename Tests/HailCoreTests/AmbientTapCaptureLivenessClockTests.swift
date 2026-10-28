import Foundation
import Testing
@testable import HailCore

@MainActor
@Suite struct AmbientTapCaptureLivenessClockTests {
    @Test func pollingKeepsALiveOwnerAndHealsOnlyAfterItEnds() async {
        let clock = TapCaptureLivenessClock()
        let playback = ReplyPlaybackController(player: DuplexPlayer())
        clock.install(on: playback)
        defer { clock.stop() }
        let owner = UUID()
        var live = true
        CapturePlaybackSuppression.liveness[owner] = { live }
        CapturePlaybackSuppression.begin(owner, using: playback)
        await clock.poll()
        #expect(playback.isCaptureSuppressed)
        #expect(CapturePlaybackSuppression.hasLedger(for: playback))
        #expect(CapturePlaybackSuppression.liveness[owner]?() == true)
        #expect(clock.intervals == [.seconds(1), .seconds(1)])
        live = false
        #expect(await clock.advanceUntilHeal(using: playback) == 1)
        #expect(!playback.isCaptureSuppressed)
        #expect(!CapturePlaybackSuppression.hasLedger(for: playback))
        #expect(CapturePlaybackSuppression.liveness[owner] == nil)
    }

    @Test func advancingOnePlayerCannotHealAnotherPlayer() async {
        let firstClock = TapCaptureLivenessClock()
        let secondClock = TapCaptureLivenessClock()
        let first = ReplyPlaybackController(player: DuplexPlayer())
        let second = ReplyPlaybackController(player: DuplexPlayer())
        firstClock.install(on: first)
        secondClock.install(on: second)
        defer { firstClock.stop(); secondClock.stop() }
        CapturePlaybackSuppression.begin(UUID(), using: first)
        CapturePlaybackSuppression.begin(UUID(), using: second)
        #expect(await firstClock.advanceUntilHeal(using: first) == 1)
        #expect(!first.isCaptureSuppressed)
        #expect(second.isCaptureSuppressed)
        #expect(CapturePlaybackSuppression.hasLedger(for: second))
        #expect(await secondClock.advanceUntilHeal(using: second) == 1)
        #expect(!second.isCaptureSuppressed)
        #expect(!CapturePlaybackSuppression.hasLedger(for: second))
    }
}
