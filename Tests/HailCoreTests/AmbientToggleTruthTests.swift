import AVFAudio
import Foundation
import HailProtocol
import Testing
@testable import HailCore

/// #218: the system stopping the engine underneath capture (a call, Siri, a route or hardware change) ends the
/// capture stream, so the ambient toggle turns off and "Listening" disappears. Nothing restarts by itself.
@Suite struct AudioCaptureEndingSignalTests {
    private typealias Names = AudioCaptureEndingSignal.Names

    @Test func anInterruptionEndsCaptureAndItsEndDoesNotResume() throws {
        let began = try #require(AudioCaptureEndingSignal(Notification(
            name: Names.interruption, userInfo: [Names.interruptionTypeKey: UInt(1)]
        )))
        #expect(began == .interruptionBegan)
        #expect(began.endsCapture(engineRunning: true))

        let ended = try #require(AudioCaptureEndingSignal(Notification(
            name: Names.interruption, userInfo: [Names.interruptionTypeKey: UInt(0)]
        )))
        #expect(ended == .interruptionEnded)
        #expect(!ended.endsCapture(engineRunning: false))
    }

    @Test func aHardwareRouteChangeEndsCaptureEvenIfTheEngineStillRuns() throws {
        for reason: UInt in [1, 2, 4, 6, 7] {
            let signal = try #require(AudioCaptureEndingSignal(Notification(
                name: Names.routeChange, userInfo: [Names.routeChangeReasonKey: reason]
            )))
            #expect(signal == .routeChanged(reason: reason))
            #expect(signal.endsCapture(engineRunning: true))
        }
    }

    /// Capture's own session activation changes the category; that ends nothing while the engine still runs.
    @Test func otherRouteChangesAndReconfigurationEndCaptureOnlyOnceTheEngineStopped() throws {
        let category = try #require(AudioCaptureEndingSignal(Notification(
            name: Names.routeChange, userInfo: [Names.routeChangeReasonKey: UInt(3)]
        )))
        #expect(!category.endsCapture(engineRunning: true))
        #expect(category.endsCapture(engineRunning: false))
        let reconfigured = try #require(AudioCaptureEndingSignal(Notification(
            name: .AVAudioEngineConfigurationChange
        )))
        #expect(!reconfigured.endsCapture(engineRunning: true))
        #expect(reconfigured.endsCapture(engineRunning: false))
        let reset = try #require(AudioCaptureEndingSignal(Notification(name: Names.mediaServicesReset)))
        #expect(reset.endsCapture(engineRunning: true))
        #expect(AudioCaptureEndingSignal(Notification(name: Notification.Name("unrelated"))) == nil)
    }

    /// The observer forwards session signals and its own engine's reconfiguration, and nothing after it is gone.
    @Test func theObserverForwardsSimulatedNotificationsForItsRunOnly() {
        let center = NotificationCenter()
        let engine = NSObject()
        let received = Received()
        var observer: AudioCaptureEndingObserver? = AudioCaptureEndingObserver(center: center, engine: engine) {
            received.append($0, $1)
        }
        let id = observer?.id
        center.post(name: Names.interruption, object: nil, userInfo: [Names.interruptionTypeKey: UInt(1)])
        center.post(name: Names.routeChange, object: nil, userInfo: [Names.routeChangeReasonKey: UInt(2)])
        center.post(name: .AVAudioEngineConfigurationChange, object: NSObject())
        center.post(name: .AVAudioEngineConfigurationChange, object: engine)
        #expect(received.signals == [.interruptionBegan, .routeChanged(reason: 2), .engineConfigurationChanged])
        #expect(received.ids.allSatisfy { $0 == id })

        observer = nil
        center.post(name: Names.interruption, object: nil, userInfo: [Names.interruptionTypeKey: UInt(1)])
        #expect(received.signals.count == 3)
        _ = observer
    }

    final class Received: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [(AudioCaptureEndingSignal, UUID)] = []
        var signals: [AudioCaptureEndingSignal] { lock.withLock { entries.map(\.0) } }
        var ids: [UUID] { lock.withLock { entries.map(\.1) } }
        func append(_ signal: AudioCaptureEndingSignal, _ id: UUID) { lock.withLock { entries.append((signal, id)) } }
    }
}

/// #218: a fast off→on must not let the earlier stream's teardown deactivate the session the new one is using.
@MainActor
@Suite struct AmbientToggleSessionGenerationTests {
    @MainActor
    final class Harness {
        var captures: [FakeAudioCapture] = []
        var sessionActive = false
        var activations = 0
        var releases = 0
        var permission = true
        let sent = SentAudio(holding: true)
        lazy var controller = AmbientListeningController(
            // Weak (#394): the controller can call back after a test has returned and freed the harness.
            requestPermission: { [weak self] in self?.permission ?? false },
            makeStreamer: { [weak self] send in
                let capture = FakeAudioCapture()
                self?.activations += 1
                self?.sessionActive = true
                self?.captures.append(capture)
                return AmbientAudioStreamer(capture: capture, send: send)
            },
            releaseSession: { [weak self] in
                self?.releases += 1
                self?.sessionActive = false
            },
            send: { [weak self] payload, _ in await self?.record(payload) }
        )

        func record(_ payload: AudioPayload) async { await sent.send(payload) }
    }

    @Test func aStaleTeardownDoesNotReleaseTheNewSession() async throws {
        let harness = Harness()
        let current = try binding()
        await harness.controller.turnOn(for: current)
        let first = try #require(harness.captures.first)
        try first.yield(sineBuffer())
        try first.yield(sineBuffer(offset: 4_800))
        try first.yield(sineBuffer(offset: 9_600))
        try await waitUntil { await harness.sent.isHolding() }

        // Off: the first stream's teardown is stuck draining behind the held send.
        let teardown = Task { await harness.controller.turnOff() }
        try await waitUntil { await MainActor.run { !harness.controller.isOn } }
        await harness.controller.turnOn(for: current)
        #expect(harness.controller.isListening)
        #expect(harness.activations == 2)

        await harness.sent.release()
        await teardown.value
        #expect(harness.releases == 0)
        #expect(harness.sessionActive)
        #expect(harness.controller.isListening)

        await harness.controller.turnOff()
        #expect(harness.releases == 1)
        #expect(!harness.sessionActive)
    }

    @Test func aTeardownWithoutAFollowingStartStillReleasesTheSession() async throws {
        let harness = Harness()
        await harness.controller.turnOn(for: try binding())
        await harness.sent.release()
        await harness.controller.turnOff()
        #expect(harness.releases == 1)
        #expect(!harness.sessionActive)
    }

    /// The simulated interruption path: capture ending its stream turns the toggle off and clears "Listening".
    @Test func captureEndingUnderneathTurnsTheToggleOffWithoutRestarting() async throws {
        let harness = Harness()
        let current = try binding()
        await harness.sent.release()
        await harness.controller.turnOn(for: current)
        try #require(harness.captures.first).stop()
        // The session is released after listening turns off, not with it (#394): wait for both.
        try await waitUntil { await MainActor.run { !harness.controller.isOn && harness.releases > 0 } }
        #expect(!harness.controller.isListening)
        #expect(harness.controller.stopReason?.contains("interrupted") == true)
        #expect(harness.releases == 1)
        await harness.controller.update(binding: current, scene: .active)
        #expect(!harness.controller.isOn)
        #expect(harness.activations == 1)
    }
}
