import Dispatch
import Foundation
import Synchronization
import Testing
@testable import HailCore

@Suite struct ReplySegmentOnsetShutdownTests {
    @Test(arguments: [false, true])
    func stoppedObservationCannotAnalyseOrFireEvenAfterReplacement(_ replace: Bool) throws {
        let fixture = OnsetFixture()
        let guarder = fixture.guarder
        let authorization = Mutex(fixture.input)
        let calls = Mutex(0)
        guarder.configureSegmentOnset(input: { authorization.withLock { $0 } }, onOnset: {
            calls.withLock { $0 += 1 }
        })
        try fixture.calibrate()
        #expect(try !fixture.feed(-20, seconds: 0.2))
        fixture.clock.advance(by: .milliseconds(300))
        let read = DispatchSemaphore(value: 0)
        let resume = DispatchSemaphore(value: 0)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            defer { done.signal() }
            guard let buffer = try? onsetPCM(-20, seconds: 0.3) else { return }
            guarder.observeSegmentOnset(buffer, afterAuthorization: {
                read.signal()
                _ = resume.wait(timeout: .now() + 5)
            })
        }
        defer { resume.signal() }
        try #require(read.wait(timeout: .now() + 5) == .success)
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
        resume.signal()
        try #require(done.wait(timeout: .now() + 5) == .success)
        let after = guarder.segmentOnsetGate.diagnostics
        #expect(after.levels.counts == before.levels.counts)
        #expect(after.floors.counts == before.floors.counts)
        #expect(after.onsets == before.onsets)
        #expect(calls.withLock { $0 } == 0)
    }

    @Test func stopWaitsForAnAlreadyRunningCallback() throws {
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
        try fixture.calibrate()
        fixture.clock.advance(by: .milliseconds(300))
        DispatchQueue.global().async {
            defer { observed.signal() }
            guard let buffer = try? onsetPCM(-35, seconds: 0.3) else { return }
            guarder.observeSegmentOnset(buffer)
        }
        defer { release.signal() }
        try #require(entered.wait(timeout: .now() + 5) == .success)
        DispatchQueue.global().async {
            stopping.signal()
            guarder.stopSegmentOnset()
            stopped.signal()
        }
        try #require(stopping.wait(timeout: .now() + 5) == .success)
        #expect(stopped.wait(timeout: .now() + 0.02) == .timedOut)
        release.signal()
        try #require(stopped.wait(timeout: .now() + 5) == .success)
        #expect(completed.withLock { $0 })
        try #require(observed.wait(timeout: .now() + 5) == .success)
        #expect(guarder.segmentOnsetGate.diagnostics.onsets == 1)
    }
}
