import AVFAudio
import Foundation
import Synchronization
@testable import HailCore

/// Engine operations that count starts and stops, and can refuse a start, with no microphone (#443).
@MainActor
final class CountingEngineOperations {
    var running = false
    var tap: AudioEngineOperations.Tap?
    var starts = 0
    var stops = 0
    var failNextStart = false

    var operations: AudioEngineOperations {
        AudioEngineOperations(
            installTap: { [unowned self] _, tap in self.tap = tap },
            removeTap: { [unowned self] _ in tap = nil },
            start: { [unowned self] _ in
                starts += 1
                if failNextStart {
                    failNextStart = false
                    throw CocoaError(.featureUnsupported)
                }
                running = true
            },
            stop: { [unowned self] _ in
                stops += 1
                running = false
            },
            isRunning: { [unowned self] _ in running }
        )
    }

    func feed(_ buffer: AVAudioPCMBuffer) { tap?(buffer, AVAudioTime(hostTime: 0)) }
}

/// A watchdog clock the test steps by hand: each `sleep` waits for `tick`, which also advances `now`.
final class SteppedSleeper: Sendable {
    private let waiting = Mutex<CheckedContinuation<Void, any Error>?>(nil)
    let clock = TestInstantClock()

    var isWaiting: Bool { waiting.withLock { $0 != nil } }

    func sleep(_ duration: Duration) async throws {
        try await withCheckedThrowingContinuation { continuation in
            waiting.withLock { $0 = continuation }
        }
    }

    /// Moves time on by `duration` and wakes the watchdog's pending sleep.
    func tick(_ duration: Duration = .seconds(1)) {
        clock.advance(by: duration)
        waiting.withLock { pending in
            pending?.resume()
            pending = nil
        }
    }
}

/// Collects every notification of `names` posted on `center`.
final class PostedNotes: @unchecked Sendable {
    private let lock = NSLock()
    private var notes: [Notification] = []
    private var tokens: [any NSObjectProtocol] = []

    init(_ center: NotificationCenter, _ names: [Notification.Name]) {
        tokens = names.map { name in
            center.addObserver(forName: name, object: nil, queue: nil) { [weak self] note in
                guard let self else { return }
                lock.withLock { notes.append(note) }
            }
        }
    }

    func named(_ name: Notification.Name) -> [Notification] { lock.withLock { notes.filter { $0.name == name } } }
}
