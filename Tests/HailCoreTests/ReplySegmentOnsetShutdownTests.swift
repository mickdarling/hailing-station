import Dispatch
import Foundation
import Synchronization
import Testing
@testable import HailCore

@Suite struct ReplySegmentOnsetShutdownTests {
    @Test(arguments: [false, true])
    func stoppedObservationCannotAnalyseOrFireEvenAfterReplacement(_ replace: Bool) async throws {
        let fixture = OnsetFixture()
        let guarder = fixture.guarder
        let authorization = Mutex(fixture.input)
        let calls = Mutex(0)
        guarder.configureSegmentOnset(input: { authorization.withLock { $0 } }, onOnset: {
            calls.withLock { $0 += 1 }
        })
        guarder.segmentOnsetGate.openWindow()
        try fixture.calibrate()
        #expect(try !fixture.feed(-20, seconds: 0.2))
        fixture.clock.advance(by: .milliseconds(300))
        let blocked = BlockedObservation.start(on: guarder)
        defer { blocked.resume.signal() }
        try #require(await waitForSignal(blocked.read) == .success)
        fixture.privacy = true
        fixture.ambient = false
        fixture.window = nil
        authorization.withLock { $0 = fixture.input }
        guarder.segmentOnsetGate.closeWindow()
        guarder.stopSegmentOnset()
        if replace {
            guarder.configureSegmentOnset(input: { authorization.withLock { $0 } }, onOnset: {
                calls.withLock { $0 += 1 }
            })
        }
        let before = guarder.segmentOnsetGate.diagnostics
        blocked.resume.signal()
        try #require(await waitForSignal(blocked.done) == .success)
        let after = guarder.segmentOnsetGate.diagnostics
        #expect(after.levels.counts == before.levels.counts)
        #expect(after.floors.counts == before.floors.counts)
        #expect(after.onsets == before.onsets)
        #expect(calls.withLock { $0 } == 0)
    }

    @Test func stopWaitsForAnAlreadyRunningCallback() async throws {
        let fixture = OnsetFixture()
        let guarder = fixture.guarder
        let input = fixture.input
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let observed = DispatchSemaphore(value: 0)
        let stopping = DispatchSemaphore(value: 0)
        let stopped = DispatchSemaphore(value: 0)
        let completed = Mutex(false)
        guarder.configureSegmentOnset(input: { input }, onOnset: {
            entered.signal()
            _ = release.wait(timeout: .now() + 5)
            completed.withLock { $0 = true }
        })
        guarder.segmentOnsetGate.openWindow()
        try fixture.calibrate()
        fixture.clock.advance(by: .milliseconds(300))
        // Sync test bodies can occupy every cooperative thread on a small runner, leaving the global
        // queue unable to start an observer (CI run 40456158789). Use dedicated threads and await waits.
        Thread {
            defer { observed.signal() }
            guard let buffer = try? onsetPCM(-35, seconds: 0.3) else { return }
            guarder.observeSegmentOnset(buffer)
        }.start()
        defer { release.signal() }
        try #require(await waitForSignal(entered) == .success)
        Thread {
            stopping.signal()
            guarder.stopSegmentOnset()
            stopped.signal()
        }.start()
        try #require(await waitForSignal(stopping) == .success)
        #expect(await waitForSignal(stopped, seconds: 0.02) == .timedOut)
        release.signal()
        try #require(await waitForSignal(stopped) == .success)
        #expect(completed.withLock { $0 })
        try #require(await waitForSignal(observed) == .success)
        #expect(guarder.segmentOnsetGate.diagnostics.onsets == 1)
    }
}

/// An observation of 300 ms at −20 dBFS that blocks just after reading authorization until `resume` is signalled.
private struct BlockedObservation {
    let read = DispatchSemaphore(value: 0)
    let resume = DispatchSemaphore(value: 0)
    let done = DispatchSemaphore(value: 0)

    static func start(on guarder: AmbientReplyEchoGuard) -> Self {
        let blocked = Self()
        Thread {
            defer { blocked.done.signal() }
            guard let buffer = try? onsetPCM(-20, seconds: 0.3) else { return }
            guarder.observeSegmentOnset(buffer, afterAuthorization: {
                blocked.read.signal()
                _ = blocked.resume.wait(timeout: .now() + 5)
            })
        }.start()
        return blocked
    }
}

/// Suspend the test task while a dedicated thread performs the bounded wait, including the negative check.
private func waitForSignal(_ semaphore: DispatchSemaphore, seconds: Double = 5) async -> DispatchTimeoutResult {
    await withCheckedContinuation { continuation in
        Thread {
            continuation.resume(returning: semaphore.wait(timeout: .now() + seconds))
        }.start()
    }
}
