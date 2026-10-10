import AVFAudio
import Foundation
import Synchronization
import Testing
@testable import HailCore

private typealias Names = AudioCaptureEndingSignal.Names

/// A clock the test moves by hand.
private final class SteppedClock: Sendable {
    private let instant = Mutex(ContinuousClock.now)
    var now: ContinuousClock.Instant { instant.withLock { $0 } }
    func advance(_ duration: Duration) { instant.withLock { $0 += duration } }
}

private func routeChange(_ reason: UInt) -> Notification {
    Notification(name: Names.routeChange, object: nil, userInfo: [Names.routeChangeReasonKey: reason])
}

/// #459: on an iPad with a USB mic, the app restored a saved built-in preference right as ambient started; iOS
/// reported that switch as reason=override, a different input, so capture ended and listening turned itself off.
@Suite struct AppRouteOverrideSignalTests {
    @Test func anOverrideInsideTheAppsOwnWindowEndsCaptureOnlyIfTheEngineStopped() throws {
        let clock = SteppedClock()
        let window = AppRouteOverrideWindow(now: { clock.now })
        window.open()
        let parsed = AudioCaptureEndingSignal(
            routeChange(4), inputChanged: { _ in true }, overrideWindow: window
        )
        let signal = try #require(parsed)
        #expect(signal == .routeChanged(reason: 4, inputChanged: true, selfOverride: true))
        #expect(!signal.endsCapture(engineRunning: true))
        #expect(signal.endsCapture(engineRunning: false))
    }

    @Test func theSameOverrideAfterTheWindowClosesStillEndsCapture() throws {
        let clock = SteppedClock()
        let window = AppRouteOverrideWindow(now: { clock.now })
        window.open()
        clock.advance(AppRouteOverrideWindow.duration + .milliseconds(1))
        let parsed = AudioCaptureEndingSignal(
            routeChange(4), inputChanged: { _ in true }, overrideWindow: window
        )
        let signal = try #require(parsed)
        #expect(signal == .routeChanged(reason: 4, inputChanged: true, selfOverride: false))
        #expect(signal.endsCapture(engineRunning: true))
    }

    @Test func aNeverOpenedWindowLeavesEveryOverrideFatal() throws {
        let window = AppRouteOverrideWindow()
        let parsed = AudioCaptureEndingSignal(
            routeChange(4), inputChanged: { _ in true }, overrideWindow: window
        )
        let signal = try #require(parsed)
        #expect(signal.endsCapture(engineRunning: true))
    }

    /// Only `override` is the app's own doing; a device unplugged inside the window still ends capture.
    @Test func otherRouteReasonsInsideTheWindowAreUnchanged() throws {
        let window = AppRouteOverrideWindow()
        window.open()
        let parsedUnplugged = AudioCaptureEndingSignal(
            routeChange(2), inputChanged: { _ in true }, overrideWindow: window
        )
        let unplugged = try #require(parsedUnplugged)
        #expect(unplugged == .routeChanged(reason: 2, inputChanged: true, selfOverride: false))
        #expect(unplugged.endsCapture(engineRunning: true))
    }

    @Test func aRealInterruptionStillEndsCaptureWhileTheWindowIsOpen() throws {
        let window = AppRouteOverrideWindow()
        window.open()
        let note = Notification(name: Names.interruption, object: nil, userInfo: [Names.interruptionTypeKey: UInt(1)])
        let parsed = AudioCaptureEndingSignal(note, overrideWindow: window)
        let signal = try #require(parsed)
        #expect(signal.endsCapture(engineRunning: true))
    }

    @Test func endReasonsNameWhatEndedTheRun() {
        #expect(AudioCaptureEndingSignal.interruptionBegan.endReason == "system_interruption")
        #expect(AudioCaptureEndingSignal.routeChanged(reason: 4).endReason == "override")
        #expect(AudioCaptureEndingSignal.routeChanged(reason: 2).endReason == "old_device_unavailable")
        #expect(AudioCaptureEndingSignal.mediaServicesReset.endReason == "capture_ended")
        #expect(AudioCaptureEndingSignal.engineConfigurationChanged.endReason == "capture_ended")
    }
}

/// The same, through a running capture: the app's own override leaves it recording, a later one ends it and says why.
@MainActor
@Suite struct AppRouteOverrideCaptureTests {
    final class Ended: @unchecked Sendable {
        private let reasons = Mutex<[String?]>([])
        func record(_ reason: String?) { reasons.withLock { $0.append(reason) } }
        var all: [String?] { reasons.withLock { $0 } }
    }

    private func capture(window: AppRouteOverrideWindow, center: NotificationCenter, fake: FakeEngineOperations)
        -> AVAudioEngineCapture {
        AVAudioEngineCapture(
            engine: AVAudioEngine(), notificationCenter: center, operations: fake.operations,
            routeInputChanged: { _ in true }, routeOverrideWindow: window
        )
    }

    @Test func theAppsOwnOverrideLeavesARunningCaptureRecording() async throws {
        let center = NotificationCenter()
        let fake = FakeEngineOperations()
        let window = AppRouteOverrideWindow()
        let capture = capture(window: window, center: center, fake: fake)
        let ended = Ended()
        let token = center.addObserver(forName: AVAudioEngineCapture.endedBySystem, object: capture, queue: nil) {
            ended.record($0.userInfo?[AVAudioEngineCapture.endedReasonKey] as? String)
        }
        defer { center.removeObserver(token) }
        let stream = try capture.start()
        window.open()
        center.post(routeChange(4))
        for _ in 0..<20 { await Task.yield() }
        #expect(fake.running)
        #expect(ended.all.isEmpty)
        capture.stop()
        withExtendedLifetime(stream) {}
    }

    @Test func anOverrideOutsideTheWindowEndsTheRunAndNamesTheReason() async throws {
        let center = NotificationCenter()
        let fake = FakeEngineOperations()
        let clock = SteppedClock()
        let window = AppRouteOverrideWindow(now: { clock.now })
        let capture = capture(window: window, center: center, fake: fake)
        let ended = Ended()
        let token = center.addObserver(forName: AVAudioEngineCapture.endedBySystem, object: capture, queue: nil) {
            ended.record($0.userInfo?[AVAudioEngineCapture.endedReasonKey] as? String)
        }
        defer { center.removeObserver(token) }
        let stream = try capture.start()
        window.open()
        clock.advance(.seconds(2))
        center.post(routeChange(4))
        try await waitUntil { !ended.all.isEmpty }
        #expect(!fake.running)
        #expect(ended.all == ["override"])
        withExtendedLifetime(stream) {}
    }

    @Test func anInterruptionEndsTheRunAsASystemInterruption() async throws {
        let center = NotificationCenter()
        let fake = FakeEngineOperations()
        let window = AppRouteOverrideWindow()
        window.open()
        let capture = capture(window: window, center: center, fake: fake)
        let ended = Ended()
        let token = center.addObserver(forName: AVAudioEngineCapture.endedBySystem, object: capture, queue: nil) {
            ended.record($0.userInfo?[AVAudioEngineCapture.endedReasonKey] as? String)
        }
        defer { center.removeObserver(token) }
        let stream = try capture.start()
        center.post(name: Names.interruption, object: nil, userInfo: [Names.interruptionTypeKey: UInt(1)])
        try await waitUntil { !ended.all.isEmpty }
        #expect(ended.all == ["system_interruption"])
        withExtendedLifetime(stream) {}
    }
}
