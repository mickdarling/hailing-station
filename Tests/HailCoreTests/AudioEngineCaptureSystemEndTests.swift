import AVFAudio
import Foundation
import HailProtocol
import Testing
@testable import HailCore

/// Engine operations that simulate the system around one capture run, with no microphone.
@MainActor
final class FakeEngineOperations {
    var running = false
    var tap: AudioEngineOperations.Tap?
    /// Runs inside `start`, after the engine reports running: models a notification landing mid-start.
    var duringStart: (@MainActor () -> Void)?

    /// Weak, not unowned (#574): a streamer's task can stop its capture after the test has dropped this fake, and an
    /// unowned read then traps the whole test process. A fake that is gone simply reports a stopped engine.
    var operations: AudioEngineOperations {
        AudioEngineOperations(
            installTap: { [weak self] _, tap in self?.tap = tap },
            removeTap: { [weak self] _ in self?.tap = nil },
            start: { [weak self] _ in
                self?.running = true
                self?.duringStart?()
            },
            stop: { [weak self] _ in self?.running = false },
            isRunning: { [weak self] _ in self?.running ?? false }
        )
    }

    func feed(_ buffer: AVAudioPCMBuffer) { tap?(buffer, AVAudioTime(hostTime: 0)) }
}

private typealias Names = AudioCaptureEndingSignal.Names

/// #218 review round 1 (Codex P2): stop observers are installed before the engine starts, so a call or route
/// change that lands during startup still ends the run.
@MainActor
@Suite struct AudioEngineCaptureStartupSignalTests {
    @Test func anInterruptionDuringStartEndsTheRun() async throws {
        let center = NotificationCenter()
        let fake = FakeEngineOperations()
        let capture = AVAudioEngineCapture(
            engine: AVAudioEngine(), notificationCenter: center, operations: fake.operations
        )
        fake.duringStart = {
            center.post(name: Names.interruption, object: nil, userInfo: [Names.interruptionTypeKey: UInt(1)])
        }
        let ended = EndedFlag()
        let token = center.addObserver(forName: AVAudioEngineCapture.endedBySystem, object: capture, queue: nil) { _ in
            ended.set()
        }
        defer { center.removeObserver(token) }

        let stream = try capture.start()
        try await waitUntil { ended.value }
        #expect(!fake.running)
        withExtendedLifetime(stream) {}
        #expect(fake.tap == nil)
        #expect(ended.value)
    }

    /// The category change capture's own session activation causes must not end a run whose engine is running.
    @Test func aCategoryChangeDuringStartLeavesARunningEngineAlone() async throws {
        let center = NotificationCenter()
        let fake = FakeEngineOperations()
        let capture = AVAudioEngineCapture(
            engine: AVAudioEngine(), notificationCenter: center, operations: fake.operations
        )
        fake.duringStart = {
            center.post(name: Names.routeChange, object: nil, userInfo: [Names.routeChangeReasonKey: UInt(3)])
        }
        let stream = try capture.start()
        for _ in 0..<20 { await Task.yield() }
        withExtendedLifetime(stream) {}
        #expect(fake.running)
        #expect(fake.tap != nil)
        capture.stop()
        #expect(!fake.running)
        withExtendedLifetime(stream) {}
    }

    final class EndedFlag: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        var value: Bool { lock.withLock { flag } }
        func set() { lock.withLock { flag = true } }
    }
}

/// #218 review round 1 (Codex P2): a system end turns the toggle and "Listening" off at once, even while earlier
/// audio is still draining behind a backpressured sender. A hardware route change ends it; an interruption now
/// pauses instead (#445, AmbientInterruptionPauseTests).
@MainActor
@Suite struct AmbientToggleDrainingInterruptionTests {
    @Test func theToggleDropsBeforeTheBacklogDrains() async throws {
        let center = NotificationCenter()
        let fake = FakeEngineOperations()
        let sent = SentAudio(holding: true)
        var releases = 0
        let controller = AmbientListeningController(
            notificationCenter: center,
            requestPermission: { true },
            makeStreamer: { send in
                let capture = AVAudioEngineCapture(
                    engine: AVAudioEngine(), notificationCenter: center, operations: fake.operations
                )
                return AmbientAudioStreamer(capture: capture, send: send)
            },
            releaseSession: { releases += 1 },
            send: { payload, _ in await sent.send(payload) }
        )
        await controller.turnOn(for: try binding())
        #expect(controller.isListening)
        fake.feed(try sineBuffer())
        fake.feed(try sineBuffer(offset: 4_800))
        fake.feed(try sineBuffer(offset: 9_600))
        try await waitUntil { await sent.isHolding() }

        center.post(name: Names.routeChange, object: nil, userInfo: [Names.routeChangeReasonKey: UInt(2)])
        try await waitUntil { await MainActor.run { !controller.isOn } }
        #expect(!controller.isListening)
        #expect(controller.stopReason?.contains("interrupted") == true)
        #expect(await sent.isHolding())
        #expect(!fake.running)

        await sent.release()
        try await waitUntil { await MainActor.run { releases == 1 } }
        await controller.update(binding: nil, scene: .active)
        #expect(!controller.isOn)
    }
}
