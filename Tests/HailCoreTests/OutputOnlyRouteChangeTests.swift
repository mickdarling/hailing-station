import AVFAudio
import Foundation
import Testing
@testable import HailCore

/// #343 follow-up: AirPods attaching as an A2DP output mid-capture ended tap-to-talk (`new_device_available`, then
/// `ended_by_system`). A hardware route change that leaves the input unchanged no longer ends a running capture.
@MainActor
@Suite struct OutputOnlyRouteChangeTests {
    private typealias Names = AudioCaptureEndingSignal.Names

    @Test func anOutputOnlyHardwareChangeLeavesARunningCaptureAlone() {
        for reason: UInt in [1, 2, 4, 6] {
            let signal = AudioCaptureEndingSignal.routeChanged(reason: reason, inputChanged: false)
            #expect(!signal.endsCapture(engineRunning: true))
            #expect(signal.endsCapture(engineRunning: false))
        }
    }

    @Test func aHardwareChangeToTheInputStillEndsCapture() {
        for reason: UInt in [1, 2, 4, 6, 7] {
            #expect(AudioCaptureEndingSignal.routeChanged(reason: reason, inputChanged: true)
                .endsCapture(engineRunning: true))
        }
    }

    @Test func noSuitableRouteEndsCaptureEvenWithTheSameInput() {
        #expect(AudioCaptureEndingSignal.routeChanged(reason: 7, inputChanged: false).endsCapture(engineRunning: true))
    }

    @Test func inputsCompareAsSetsOfPortIdentifiers() {
        #expect(!AudioCaptureEndingSignal.inputsDiffer(previous: ["mic"], current: ["mic"]))
        #expect(AudioCaptureEndingSignal.inputsDiffer(previous: ["mic"], current: ["headset"]))
        #expect(AudioCaptureEndingSignal.inputsDiffer(previous: ["mic"], current: []))
    }

    /// Off iOS there is no session route to compare, so the old behaviour (end on a hardware change) holds.
    @Test func withoutAPreviousRouteTheInputCountsAsChanged() {
        let notification = Notification(name: Names.routeChange, userInfo: [Names.routeChangeReasonKey: UInt(1)])
        #expect(AudioCaptureEndingSignal.inputChanged(notification))
        #expect(AudioCaptureEndingSignal(notification) == .routeChanged(reason: 1, inputChanged: true))
    }

    @Test func aNewOutputDeviceDoesNotEndARunningEngineCapture() async throws {
        let run = Run(inputChanged: false)
        let stream = try run.capture.start()
        run.postNewDevice()
        for _ in 0..<20 { await Task.yield() }
        #expect(run.fake.running)
        #expect(run.fake.tap != nil)
        #expect(!run.ended.value)
        await run.finish(stream)
    }

    @Test func aNewInputDeviceStillEndsEngineCapture() async throws {
        let run = Run(inputChanged: true)
        let stream = try run.capture.start()
        run.postNewDevice()
        try await waitUntil { run.ended.value }
        #expect(!run.fake.running)
        await run.finish(stream)
    }

    /// Mick's setup: a USB wireless mic as input and AirPods as output. Ambient resolves to plain capture (no VPIO,
    /// so the AirPods keep A2DP), the input preference still picks the USB mic over the built-in one, and the
    /// AirPods attaching mid-capture leaves the USB input, and so the capture, alone.
    @Test func aUSBMicWithAirPodsKeepsUSBInputAndPlainCapture() {
        let usb = AudioPort(id: "usb-mic", name: "USB", kind: .usb)
        let builtIn = AudioPort(id: "built-in", name: "Microphone", kind: .builtIn)
        #expect(AudioInputPreferences().resolve(from: [builtIn, usb]) == usb)
        #expect(AmbientCaptureModeResolver.mode(for: [.bluetoothA2DP]) == .plain)
        #expect(!AudioCaptureEndingSignal.inputsDiffer(previous: [usb.id], current: [usb.id]))
        #expect(!AudioCaptureEndingSignal.routeChanged(reason: 1, inputChanged: false).endsCapture(engineRunning: true))
    }

    /// One engine capture on a private notification center, with the input comparison fixed.
    @MainActor
    final class Run {
        let center = NotificationCenter()
        let fake = FakeEngineOperations()
        let ended = AudioEngineCaptureStartupSignalTests.EndedFlag()
        let capture: AVAudioEngineCapture
        private var token: (any NSObjectProtocol)?

        init(inputChanged: Bool) {
            capture = AVAudioEngineCapture(
                engine: AVAudioEngine(), notificationCenter: center, operations: fake.operations,
                routeInputChanged: { _ in inputChanged }
            )
            let ended = ended
            token = center.addObserver(forName: AVAudioEngineCapture.endedBySystem, object: capture, queue: nil) { _ in
                ended.set()
            }
        }

        /// Stops the run and lets its stream-termination work finish while the fake engine is still alive.
        func finish(_ stream: AsyncStream<AudioCaptureBuffer>) async {
            capture.stop()
            withExtendedLifetime(stream) {}
            for _ in 0..<20 { await Task.yield() }
        }

        func postNewDevice() {
            center.post(name: Names.routeChange, object: nil, userInfo: [Names.routeChangeReasonKey: UInt(1)])
        }
    }
}
