import Foundation
import Testing
@testable import HailCore

/// A per-player manual sleep: continuations suspend tasks without blocking a cooperative thread.
@MainActor
final class TapCaptureLivenessClock {
    private(set) var intervals: [Duration] = []
    private var pending: CheckedContinuation<Void, any Error>?
    private var scheduled: CheckedContinuation<Void, Never>?
    private var completion: CheckedContinuation<Int, Never>?
    private var backstop: Task<Void, Never>?
    private var backstopID: UUID?
    private weak var reportingPlayback: ReplyPlaybackController?
    private var healedCount: Int?
    private var expiredWait: String?
    private var stopped = false

    func install(on playback: ReplyPlaybackController) {
        playback.captureLivenessSleep = { try await self.sleep($0) }
    }

    private func sleep(_ interval: Duration) async throws {
        if stopped { throw CancellationError() }
        guard pending == nil else {
            Issue.record("TapCaptureLivenessClock received overlapping sleeps")
            stop()
            throw CancellationError()
        }
        intervals.append(interval)
        try await withCheckedThrowingContinuation { continuation in
            pending = continuation
            if let registration = scheduled {
                scheduled = nil
                cancelBackstop()
                registration.resume()
            }
        }
    }

    private func waitForSleep() async {
        guard !stopped else { return }
        guard scheduled == nil, completion == nil else {
            Issue.record("TapCaptureLivenessClock received overlapping waits")
            stop()
            return
        }
        guard pending == nil else { return }
        await withCheckedContinuation {
            scheduled = $0
            armBackstop(for: "waitForSleep")
        }
        recordExpiry()
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

    /// Register before waking the watcher; only its existing heal notification completes a successful wait.
    func advanceUntilHeal(using playback: ReplyPlaybackController) async -> Int {
        await waitForSleep()
        guard !stopped else { return 0 }
        defer { CapturePlaybackSuppression.reportHeals(for: playback, to: nil) }
        reportingPlayback = playback
        let count = await withCheckedContinuation {
            completion = $0
            armBackstop(for: "advanceUntilHeal")
            CapturePlaybackSuppression.reportHeals(for: playback) { count in
                guard !self.stopped else { return }
                self.healedCount = count
                self.stop()
            }
            advance()
        }
        recordExpiry()
        return count
    }

    func stop() {
        stopped = true
        cancelBackstop()
        if let playback = reportingPlayback { CapturePlaybackSuppression.reportHeals(for: playback, to: nil) }
        reportingPlayback = nil
        let sleeper = pending
        pending = nil
        let registration = scheduled
        scheduled = nil
        let healing = completion
        completion = nil
        sleeper?.resume(throwing: CancellationError())
        registration?.resume()
        healing?.resume(returning: healedCount ?? 0)
    }

    /// Independent real time is only a failure net; successful waits resume from registration or the heal.
    private func armBackstop(for wait: String) {
        cancelBackstop()
        let identifier = UUID()
        backstopID = identifier
        backstop = Task.detached { [weak self] in
            do { try await Task.sleep(for: .seconds(30)) } catch { return }
            await self?.expire(wait, identifier: identifier)
        }
    }

    private func cancelBackstop() {
        backstopID = nil
        backstop?.cancel()
        backstop = nil
    }

    private func expire(_ wait: String, identifier: UUID) {
        guard backstopID == identifier else { return }
        expiredWait = wait
        stop()
    }

    /// Record in the waiting test's task: detached timers do not inherit Swift Testing's task-local context.
    private func recordExpiry() {
        guard let wait = expiredWait else { return }
        expiredWait = nil
        Issue.record("""
            TapCaptureLivenessClock \(wait) expired after 30 s; \
            sleeps registered: \(intervals.count); heal reported: \(healedCount != nil)
            """)
    }
}
