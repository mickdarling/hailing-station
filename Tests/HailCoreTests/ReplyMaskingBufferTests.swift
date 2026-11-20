import Foundation
import HailProtocol
import Testing
@testable import HailCore

@MainActor
@Suite struct ReplyMaskingBufferTests {
    let suite = "hail-masking-buffer-\(UUID().uuidString)"
    var defaults: UserDefaults { UserDefaults(suiteName: suite) ?? .standard }

    func log(_ storage: UserDefaults? = nil,
             clock: @escaping @Sendable () -> ContinuousClock.Instant = { .now }) -> DeviceDiagnostics {
        let log = DeviceDiagnostics(defaults: storage ?? defaults, appInfo: [:], clock: clock)
        log.setEnabled(true)
        _ = log.nextBatch()
        return log
    }

    @Test func pendingMaskingEdgesPrecedeBothLegacyTapEdges() throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = EchoGuardClock(), log = log(), token = UUID()
        let guarder = AmbientReplyEchoGuard(now: { clock.now })
        guarder.diagnostics = log
        guarder.beginMaskingReport(token, mode: .plain)
        _ = log.nextBatch()
        guarder.setReplyAudible(true)
        #expect(guarder.silenceIfMasking(try sineBuffer(), capture: token))
        clock.advance(by: .seconds(1))
        guarder.setTapCaptureActive(true)
        #expect(guarder.silenceIfMasking(try sineBuffer(), capture: token))
        guarder.setTapCaptureActive(false)
        let events = try #require(log.nextBatch()).events
        try #require(events.count == 5)
        #expect(events.map { $0.fields[.masking] } == [.boolean(true), nil, .boolean(false), .boolean(true), nil])
        #expect(events[1].fields[.state] == .token("tap_to_talk_start"))
        #expect(events[4].fields[.state] == .token("tap_to_talk_end"))
        #expect(events[2].fields[.reason] == .token("plain_capture"))
        #expect(events[3].fields[.reason] == .token("tap_to_talk"))
        #expect(events[2].timestamp == events[3].timestamp) // Off/on at one instant is not an open mic.
        #expect(events[2].fields[.ms] == .integer(1_000))
        guarder.endMaskingReport(token)
    }

    @Test func aStaleBufferCannotReportForItsReplacementCapture() throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let guarder = AmbientReplyEchoGuard(), log = log(), old = UUID(), current = UUID()
        guarder.diagnostics = log
        guarder.beginMaskingReport(old, mode: .plain)
        guarder.setReplyAudible(true)
        #expect(guarder.silenceIfMasking(try sineBuffer(), capture: old))
        guarder.beginMaskingReport(current, mode: .voiceProcessing)
        guarder.setRoutedThroughCapture(true)
        #expect(!guarder.silenceIfMasking(try sineBuffer(), capture: current))
        _ = log.nextBatch()
        guarder.masksDuringReplies = true
        // Samples still follow the original predicate; only reporting is fenced by the capture token.
        #expect(guarder.silenceIfMasking(try sineBuffer(), capture: old))
        guarder.flushMaskingDiagnostics()
        #expect(log.nextBatch() == nil)
        #expect(guarder.silenceIfMasking(try sineBuffer(), capture: current))
        guarder.endMaskingReport(current)
        let edges = try #require(log.nextBatch()).events
        #expect(edges.map { $0.fields[.masking] } == [.boolean(true), .boolean(false)])
    }

    @Test func attachingADifferentLogDiscardsPendingEdgesAndRestartsTheInterval() throws {
        let replacementSuite = suite + ".replacement"
        let replacement = try #require(UserDefaults(suiteName: replacementSuite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            replacement.removePersistentDomain(forName: replacementSuite)
        }
        let clock = EchoGuardClock(), first = log(), second = log(replacement), token = UUID()
        #expect(first.generation == second.generation) // Identity must fence even equal generation numbers.
        let guarder = AmbientReplyEchoGuard(now: { clock.now })
        guarder.diagnostics = first
        guarder.beginMaskingReport(token, mode: .plain)
        _ = first.nextBatch()
        guarder.setReplyAudible(true)
        #expect(guarder.silenceIfMasking(try sineBuffer(), capture: token))
        clock.advance(by: .seconds(1))
        guarder.diagnostics = second
        guarder.flushMaskingDiagnostics()
        #expect(second.nextBatch() == nil)
        #expect(guarder.silenceIfMasking(try sineBuffer(), capture: token))
        clock.advance(by: .milliseconds(400))
        guarder.endMaskingReport(token)
        let events = try #require(second.nextBatch()).events
        #expect(events.map(\.name) == [.captureState, .echoGuard, .echoGuard])
        #expect(events.last?.fields[.ms] == .integer(400))
        #expect(first.nextBatch() == nil)
    }

    @Test func overflowKeepsTheNewestScalarsAndReportsItsDroppedCount() throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let captureClock = EchoGuardClock(), recordingClock = TestInstantClock(), token = UUID()
        let log = log(clock: { recordingClock.now() })
        let guarder = AmbientReplyEchoGuard(tail: .zero, now: { captureClock.now })
        guarder.diagnostics = log
        guarder.beginMaskingReport(token, mode: .plain)
        _ = log.nextBatch()
        // Reuse one buffer; the test drives synchronous transitions without letting the wake task flush.
        let buffer = try sineBuffer()
        for index in 0..<(DeviceDiagnostics.capacity + 17) {
            let audible = index.isMultiple(of: 2)
            guarder.setReplyAudible(audible)
            captureClock.advance(by: .milliseconds(1))
            #expect(guarder.silenceIfMasking(buffer, capture: token) == audible)
        }
        var recorded: [DiagnosticEvent] = []
        log.onPending = {
            // Isolate ring overflow from the diagnostics log's separate rate/capacity/send limits.
            recordingClock.advance(by: .seconds(60))
            while let batch = log.nextBatch() { recorded += batch.events }
        }
        defer { log.onPending = nil }
        guarder.endMaskingReport(token) // Adds one off: 518 transitions, with the newest 500 retained.
        #expect(recorded.first?.name == .eventsDropped)
        #expect(recorded.first?.fields == [.code: .token("app_buffer"), .count: .integer(18)])
        let edges = Array(recorded.dropFirst())
        try #require(edges.count == DeviceDiagnostics.capacity)
        for (index, edge) in edges.enumerated() {
            #expect(edge.name == .echoGuard)
            #expect(edge.fields[.masking] == .boolean(index.isMultiple(of: 2)))
            #expect(edge.fields[.reason] == .token("plain_capture"))
        }
        let first = try #require(edges.first), last = try #require(edges.last)
        #expect(last.timestamp - first.timestamp == 498)
        #expect(edges[1].fields[.ms] == .integer(1))
        #expect(edges.last?.fields[.ms] == .integer(0)) // End immediately after the last on.
    }
}
