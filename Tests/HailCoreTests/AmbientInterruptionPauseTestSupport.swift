import AVFAudio
import Foundation
import HailProtocol
import Testing
@testable import HailCore

private typealias Names = AudioCaptureEndingSignal.Names

/// Each backoff wait parks until the test releases it.
actor BackoffSteps {
    private var waiters: [CheckedContinuation<Void, Never>] = []
    var pending: Int { waiters.count }
    func sleep() async { await withCheckedContinuation { waiters.append($0) } }
    func release() { if !waiters.isEmpty { waiters.removeFirst().resume() } }
}

struct MicBusy: Error {}

@MainActor
final class InterruptionPauseHarness {
    let center = NotificationCenter()
    let steps = BackoffSteps()
    let sent: SentAudio
    /// Refuses every send while set, as the host would.
    var refusal: (any Error)?
    /// What `onListeningChange` reported: listening or paused.
    var activity: [Bool] = []
    var fakes: [FakeEngineOperations] = []
    var micBusy = false
    var releases = 0
    var unexpected: [String] = []
    lazy var controller = makeController()

    init(holdingSends: Bool = false) { sent = SentAudio(holding: holdingSends) }

    func deliver(_ payload: AudioPayload) async throws {
        if let refusal { throw refusal }
        await sent.send(payload)
    }

    /// Feeds three 100 ms buffers to the newest capture, enough for at least one segment to be sent.
    func speak() throws {
        let fake = try #require(fakes.last)
        for offset in [0, 4_800, 9_600] { fake.feed(try sineBuffer(offset: offset)) }
    }

    private func makeController() -> AmbientListeningController {
        let steps = steps
        let controller = AmbientListeningController(
            notificationCenter: center,
            requestPermission: { true },
            makeStreamer: { [weak self] send in
                guard let self, !micBusy else { throw MicBusy() }
                let fake = FakeEngineOperations()
                fakes.append(fake)
                let capture = AVAudioEngineCapture(
                    engine: AVAudioEngine(), notificationCenter: center, operations: fake.operations
                )
                return AmbientAudioStreamer(capture: capture, send: send)
            },
            releaseSession: { [weak self] in self?.releases += 1 },
            sleep: { _ in await steps.sleep() },
            now: { ContinuousClock().now },
            send: { [weak self] payload, _ in try await self?.deliver(payload) }
        )
        controller.onUnexpectedStop = { [weak self] in self?.unexpected.append($0) }
        controller.onListeningChange = { [weak self] in self?.activity.append($0) }
        return controller
    }

    func interruption(began: Bool) {
        let type = UInt(began ? 1 : 0)
        center.post(name: Names.interruption, object: nil, userInfo: [Names.interruptionTypeKey: type])
    }

    func waitForBackoff() async throws {
        let steps = steps
        try await waitUntil { await steps.pending > 0 }
    }
}

/// #445: capture marks an interruption as the cause of a system end, and nothing else.
@MainActor
@Suite struct AudioEngineCaptureInterruptionCauseTests {
    /// Only an interruption marks the end; a route change or a stall still ends the run as before.
    @Test func captureTagsOnlyAnInterruptionAsTheCause() async throws {
        let center = NotificationCenter()
        let fake = FakeEngineOperations()
        let capture = AVAudioEngineCapture(
            engine: AVAudioEngine(), notificationCenter: center, operations: fake.operations
        )
        let causes = Causes()
        let token = center.addObserver(forName: AVAudioEngineCapture.endedBySystem, object: capture, queue: nil) {
            causes.append($0.userInfo?[AVAudioEngineCapture.endedCauseKey] as? String)
        }
        defer { center.removeObserver(token) }

        let first = try capture.start()
        center.post(name: Names.interruption, object: nil, userInfo: [Names.interruptionTypeKey: UInt(1)])
        try await waitUntil { causes.values.count == 1 }
        let second = try capture.start()
        center.post(name: Names.routeChange, object: nil, userInfo: [Names.routeChangeReasonKey: UInt(2)])
        try await waitUntil { causes.values.count == 2 }
        withExtendedLifetime((first, second)) {}
        #expect(causes.values == [AVAudioEngineCapture.interruptionCause, nil])
    }

    final class Causes: @unchecked Sendable {
        private let lock = NSLock()
        private var list: [String?] = []
        var values: [String?] { lock.withLock { list } }
        func append(_ cause: String?) { lock.withLock { list.append(cause) } }
    }
}
