import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailCore

private final class MaskingDrainerTasks: Sendable {
    private let starts = Mutex(0)
    var count: Int { starts.withLock { $0 } }

    func start(_ operation: @escaping @MainActor @Sendable () async -> Void) -> Task<Void, Never> {
        starts.withLock { $0 += 1 }
        return Task { @MainActor in await operation() }
    }
}

@MainActor
@Suite struct ReplyMaskingDrainerTests {
    let suite = "hail-masking-drainer-\(UUID().uuidString)"
    var defaults: UserDefaults { UserDefaults(suiteName: suite) ?? .standard }

    func log() -> DeviceDiagnostics {
        let log = DeviceDiagnostics(defaults: defaults, appInfo: [:])
        log.setEnabled(true)
        _ = log.nextBatch()
        return log
    }

    @Test func manyTransitionsAcrossDrainsStartOnlyOneTask() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let tasks = MaskingDrainerTasks(), log = log(), token = UUID()
        let guarder = AmbientReplyEchoGuard(tail: .zero, reportTask: { tasks.start($0) })
        guarder.diagnostics = log
        guarder.beginMaskingReport(token, mode: .plain)
        defer { guarder.endMaskingReport(token) }
        #expect(tasks.count == 1)
        _ = log.nextBatch()
        let (drains, drained) = AsyncStream<Void>.makeStream(bufferingPolicy: .unbounded)
        var iterator = drains.makeAsyncIterator()
        log.onPending = { drained.yield() }
        defer { log.onPending = nil; drained.finish() }
        let buffer = try sineBuffer()
        for index in 0..<32 {
            let audible = index.isMultiple(of: 2)
            guarder.setReplyAudible(audible)
            #expect(guarder.silenceIfMasking(buffer, capture: token) == audible)
            _ = await iterator.next() // Each next transition starts with an already drained ring.
            let events = try #require(log.nextBatch()).events
            #expect(events.count == 1)
            #expect(events.first?.fields[.masking] == .boolean(audible))
            #expect(tasks.count == 1) // Counts allocations, not whether a task happened to run yet.
        }
    }

    @Test func endingCaptureFinishesItsDrainerAndFlushesTheLastEdges() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = EchoGuardClock(), log = log(), token = UUID()
        let guarder = AmbientReplyEchoGuard(now: { clock.now })
        guarder.diagnostics = log
        guarder.beginMaskingReport(token, mode: .plain)
        let drainer = try #require(guarder.maskingReportDrainer)
        _ = log.nextBatch()
        guarder.setReplyAudible(true)
        #expect(guarder.silenceIfMasking(try sineBuffer(), capture: token))
        clock.advance(by: .milliseconds(400))
        // No actor suspension: end must synchronously flush the queued on and closing off.
        guarder.endMaskingReport(token)
        #expect(guarder.maskingReportDrainer == nil)
        #expect(drainer.task.isCancelled)
        guard case .terminated = drainer.wake.yield() else {
            Issue.record("The ended capture's wake stream must be finished")
            return
        }
        let events = try #require(log.nextBatch()).events
        #expect(events.map { $0.fields[.masking] } == [.boolean(true), .boolean(false)])
        #expect(events.last?.fields[.ms] == .integer(400))
        await drainer.task.value
        #expect(log.nextBatch() == nil)
    }

    @Test func aQueuedStaleDrainerCannotFlushAReplacementCapture() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let tasks = MaskingDrainerTasks(), log = log(), old = UUID(), current = UUID()
        let guarder = AmbientReplyEchoGuard(reportTask: { tasks.start($0) })
        guarder.diagnostics = log
        guarder.beginMaskingReport(old, mode: .plain)
        let stale = try #require(guarder.maskingReportDrainer)
        guarder.setReplyAudible(true)
        #expect(guarder.silenceIfMasking(try sineBuffer(), capture: old))
        guarder.beginMaskingReport(current, mode: .plain)
        defer { guarder.endMaskingReport(current) }
        #expect(tasks.count == 2)
        #expect(stale.task.isCancelled)
        _ = log.nextBatch()
        #expect(guarder.silenceIfMasking(try sineBuffer(), capture: current))
        // Invoke the actual callback retained by the old task, simulating a dequeued wake.
        // Stay on this actor so the current drainer cannot flush first and hide a missing fence.
        stale.drain()
        guarder.endMaskingReport(old)
        #expect(log.nextBatch() == nil)
        guarder.endMaskingReport(current)
        let events = try #require(log.nextBatch()).events
        #expect(events.map { $0.fields[.masking] } == [.boolean(true), .boolean(false)])
        await stale.task.value
        #expect(log.nextBatch() == nil)
    }
}
