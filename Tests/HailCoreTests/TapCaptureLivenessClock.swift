import Foundation
@testable import HailCore

/// A per-player manual sleep: continuations suspend tasks without blocking a cooperative thread.
@MainActor
final class TapCaptureLivenessClock {
    private(set) var intervals: [Duration] = []
    private var pending: CheckedContinuation<Void, any Error>?
    private var scheduled: CheckedContinuation<Void, Never>?
    private var stopped = false

    func install(on playback: ReplyPlaybackController) {
        playback.captureLivenessSleep = { try await self.sleep($0) }
    }

    private func sleep(_ interval: Duration) async throws {
        if stopped { throw CancellationError() }
        intervals.append(interval)
        try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            scheduled?.resume()
            scheduled = nil
        }
    }

    private func waitForSleep() async {
        if pending == nil { await withCheckedContinuation { scheduled = $0 } }
    }

    private func advance() {
        let continuation = pending
        pending = nil
        continuation?.resume()
    }

    /// Returning from the next sleep registration proves the preceding real watcher poll finished.
    func poll() async {
        await waitForSleep()
        advance()
        await waitForSleep()
    }

    /// Register before waking the watcher; only its existing heal notification completes this wait.
    func advanceUntilHeal(using playback: ReplyPlaybackController) async -> Int {
        await waitForSleep()
        defer { CapturePlaybackSuppression.reportHeals(for: playback, to: nil) }
        return await withCheckedContinuation { completion in
            CapturePlaybackSuppression.reportHeals(for: playback) { count in
                self.stop()
                completion.resume(returning: count)
            }
            advance()
        }
    }

    func stop() {
        stopped = true
        pending?.resume(throwing: CancellationError())
        pending = nil
    }
}
