import Foundation

/// A small synchronous fan-out primitive. Every observer receives its own bounded stream, so a SwiftUI
/// task disappearing cannot finish the stream used by another screen or by a later observer.
final class AudioSessionEventBroadcast: @unchecked Sendable {
    typealias Continuation = AsyncStream<AudioSessionEvent>.Continuation

    private let lock = NSLock()
    private var continuations: [UUID: Continuation] = [:]
    private var isFinished = false

    deinit {
        finish()
    }

    func stream() -> AsyncStream<AudioSessionEvent> {
        AsyncStream(bufferingPolicy: .bufferingNewest(16)) { continuation in
            let identifier = UUID()
            continuation.onTermination = { [weak self] _ in
                self?.remove(identifier)
            }

            lock.lock()
            if isFinished {
                lock.unlock()
                continuation.finish()
            } else {
                continuations[identifier] = continuation
                lock.unlock()
            }
        }
    }

    func yield(_ event: AudioSessionEvent) {
        lock.lock()
        let subscribers = Array(continuations.values)
        lock.unlock()
        for continuation in subscribers {
            continuation.yield(event)
        }
    }

    func finish() {
        lock.lock()
        guard !isFinished else {
            lock.unlock()
            return
        }
        isFinished = true
        let subscribers = Array(continuations.values)
        continuations.removeAll()
        lock.unlock()
        for continuation in subscribers {
            continuation.finish()
        }
    }

    var subscriberCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return continuations.count
    }

    private func remove(_ identifier: UUID) {
        lock.lock()
        continuations.removeValue(forKey: identifier)
        lock.unlock()
    }
}
