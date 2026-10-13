import Darwin
import Foundation

/// Bounded exclusive terminal control reader. Never blocks the foreground renewal/audio actor.
@MainActor final class CoachingKeyboard {
    let lines: AsyncThrowingStream<String, any Error>
    private let continuation: AsyncThrowingStream<String, any Error>.Continuation
    private let source: any DispatchSourceRead
    private var signals: [any DispatchSourceSignal] = []
    private let ended: () -> Void
    private var buffer = Data()
    private(set) var closed = false

    init(input: Int32 = STDIN_FILENO, observeSignals: Bool = true, ended: @escaping () -> Void) throws {
        let fd = dup(input)
        guard fd >= 0 else { throw CoachingCommandError.localControlRequired }
        let pair = AsyncThrowingStream<String, any Error>.makeStream(bufferingPolicy: .bufferingOldest(4))
        lines = pair.stream; continuation = pair.continuation; self.ended = ended
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .main)
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.read(fd) }
        }
        source.setCancelHandler { Darwin.close(fd) }
        source.activate()
        for number in observeSignals ? [SIGINT, SIGTERM] : [] {
            Darwin.signal(number, SIG_IGN)
            let observer = DispatchSource.makeSignalSource(signal: number, queue: .main)
            observer.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.close() } }
            observer.activate(); signals.append(observer)
        }
    }
    isolated deinit { source.cancel(); signals.forEach { $0.cancel() }; continuation.finish() }

    func close(error: Bool = false) {
        guard !closed else { return }
        closed = true
        ended() // Clear capture/TTS/child authority synchronously before delivering stream completion.
        source.cancel(); signals.forEach { $0.cancel() }
        if error { continuation.finish(throwing: CoachingCommandError.invalidControl) } else { continuation.finish() }
    }
    private func read(_ fd: Int32) {
        guard !closed else { return }
        var bytes = [UInt8](repeating: 0, count: min(128, max(1, Int(source.data))))
        let count = bytes.withUnsafeMutableBytes { Darwin.read(fd, $0.baseAddress, $0.count) }
        if count < 0, errno == EINTR { return }
        guard count > 0 else { close(error: count < 0); return }
        for byte in bytes.prefix(count) {
            if byte == 10 {
                guard let line = String(data: buffer, encoding: .ascii) else { close(error: true); return }
                buffer.removeAll(keepingCapacity: true)
                switch continuation.yield(line) {
                case .enqueued: break
                case .dropped, .terminated: close(error: true); return
                @unknown default: close(error: true); return
                }
            } else {
                guard (32...126).contains(byte), buffer.count < 96 else { close(error: true); return }
                buffer.append(byte)
            }
        }
    }
}
