import Foundation
import HailProtocol
import Testing
@testable import HailCore

/// #1213: the reported predicate is the one used to zero samples, scoped to a running capture.
@MainActor
@Suite struct ReplyMaskingDiagnosticsTests {
    let suite = "hail-masking-\(UUID().uuidString)"
    var defaults: UserDefaults { UserDefaults(suiteName: suite) ?? .standard }

    func log() -> DeviceDiagnostics {
        let log = DeviceDiagnostics(defaults: defaults, appInfo: [:])
        log.setEnabled(true)
        _ = log.nextBatch()
        return log
    }

    @Test(arguments: DiagnosticLimits.replyMaskingReasons)
    func eachReasonHasOrderedEdgesAndTheTail(reason: String) throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = EchoGuardClock(), log = log(), token = UUID()
        let guarder = AmbientReplyEchoGuard(now: { clock.now })
        guarder.diagnostics = log
        guarder.beginMaskingReport(token, mode: reason == "plain_capture" ? .plain : .voiceProcessing)
        guarder.setRoutedThroughCapture(reason != "plain_capture" && reason != "reply_not_routed")
        #expect(!guarder.silenceIfMasking(try sineBuffer(), capture: token))
        guarder.masksDuringReplies = reason == "setting"
        if reason == "tap_to_talk" { guarder.setTapCaptureActive(true) }
        guarder.setReplyAudible(true)
        #expect(guarder.silenceIfMasking(try sineBuffer(), capture: token))
        clock.advance(by: .seconds(1))
        #expect(guarder.silenceIfMasking(try sineBuffer(), capture: token))
        guarder.setReplyAudible(false)
        if reason == "tap_to_talk" { guarder.setTapCaptureActive(false) }
        clock.advance(by: .milliseconds(399))
        #expect(guarder.silenceIfMasking(try sineBuffer(), capture: token))
        clock.advance(by: .milliseconds(1))
        #expect(!guarder.silenceIfMasking(try sineBuffer(), capture: token))
        guarder.endMaskingReport(token)
        let edges = (log.nextBatch()?.events ?? []).filter { $0.fields[.masking] != nil }
        #expect(edges.map { $0.fields[.masking] } == [.boolean(true), .boolean(false)])
        #expect(edges.map { $0.fields[.reason] } == [.token(reason), .token(reason)])
        #expect(edges.allSatisfy { $0.fields[.capture] == .token(reason == "plain_capture" ? "plain" : "vpio") })
        #expect(edges.last?.fields[.ms] == .integer(1_400))
        #expect(edges.allSatisfy { $0.fields[.count] == .integer(1) })
    }

    @Test func echoCancelledRepliesAndInactiveCapturesProduceNoMaskingEdges() throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let guarder = AmbientReplyEchoGuard(), log = log(), token = UUID()
        guarder.diagnostics = log
        guarder.setReplyAudible(true)
        #expect(guarder.silenceIfMasking(try sineBuffer())) // No active ambient stream: no report.
        guarder.beginMaskingReport(token, mode: .voiceProcessing)
        guarder.setRoutedThroughCapture(true)
        #expect(!guarder.silenceIfMasking(try sineBuffer(), capture: token))
        guarder.endMaskingReport(token)
        let events = try #require(log.nextBatch()).events
        #expect(events.map(\.name) == [.captureState])
        #expect(events.first?.fields == [.capture: .token("vpio")])
    }

    @Test func reasonChangesCloseThenOpenAndOldCaptureCannotCloseNewCapture() throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let guarder = AmbientReplyEchoGuard(), log = log(), old = UUID(), current = UUID()
        guarder.diagnostics = log
        guarder.beginMaskingReport(old, mode: .plain)
        guarder.setReplyAudible(true)
        #expect(guarder.silenceIfMasking(try sineBuffer(), capture: old))
        guarder.beginMaskingReport(current, mode: .voiceProcessing)
        guarder.endMaskingReport(old)
        #expect(guarder.silenceIfMasking(try sineBuffer(), capture: current))
        guarder.masksDuringReplies = true
        #expect(guarder.silenceIfMasking(try sineBuffer(), capture: current))
        guarder.endMaskingReport(current)
        let edges = try #require(log.nextBatch()).events.filter { $0.fields[.masking] != nil }
        #expect(edges.map { $0.fields[.masking] } == Array(repeating: [.boolean(true), .boolean(false)], count: 3)
            .flatMap { $0 })
        #expect(edges.map { $0.fields[.reason] } == ["plain_capture", "plain_capture", "reply_not_routed",
                                                   "reply_not_routed", "setting", "setting"].map { .token($0) })
        #expect(edges.allSatisfy { Set($0.fields.keys).isSubset(of: [.masking, .reason, .capture, .count, .ms]) })
    }

    @Test func captureLifecycleClosesAMaskedInterval() async throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let guarder = AmbientReplyEchoGuard(), log = log(), source = FakeAudioCapture()
        guarder.diagnostics = log
        let capture = guarder.masking(source)
        let stream = try capture.start()
        guarder.setReplyAudible(true)
        try source.yield(sineBuffer())
        var iterator = stream.makeAsyncIterator()
        _ = await iterator.next()
        capture.stop()
        let edges = try #require(log.nextBatch()).events.filter { $0.fields[.masking] != nil }
        #expect(edges.map { $0.fields[.masking] } == [.boolean(true), .boolean(false)])
        #expect(edges.allSatisfy { $0.fields[.capture] == .token("other") })
    }

    @Test func maskingAndPlaybackEdgesKeepTheirOrderInOneBatch() throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let rig = AmbientDuplexPlaybackTests.Harness(), log = log(), token = UUID()
        rig.echoGuard.diagnostics = log
        rig.echoGuard.beginMaskingReport(token, mode: .plain)
        log.watch(rig.playback)
        rig.playback.ingest(duplexEvent())
        #expect(rig.echoGuard.silenceIfMasking(try sineBuffer(), capture: token))
        log.watch(rig.playback) // Drains capture edges before the observer's playback edges.
        rig.player.finish()
        rig.echoGuard.setReplyAudible(false)
        log.watch(rig.playback)
        rig.clock.advance(by: .milliseconds(400))
        #expect(!rig.echoGuard.silenceIfMasking(try sineBuffer(), capture: token))
        rig.echoGuard.endMaskingReport(token)
        let events = try #require(log.nextBatch()).events
        #expect(events.map(\.name) == [.captureState, .echoGuard, .replyPlaybackStart, .echoGuard,
                                      .replyPlaybackEnd, .echoGuard, .echoGuard])
        #expect(events.map { $0.fields[.masking] } == [nil, .boolean(true), nil, nil, nil, nil, .boolean(false)])
    }
}

extension ReplyMaskingDiagnosticsTests {
    @Test func loggingGenerationsFencePendingCaptureEdges() throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = EchoGuardClock(), log = log(), token = UUID()
        let guarder = AmbientReplyEchoGuard(now: { clock.now })
        guarder.diagnostics = log
        guarder.beginMaskingReport(token, mode: .plain)
        _ = log.nextBatch()
        guarder.setReplyAudible(true)
        #expect(guarder.silenceIfMasking(try sineBuffer(), capture: token))
        log.setEnabled(false)
        log.setEnabled(true)
        _ = log.nextBatch()
        guarder.flushMaskingDiagnostics()
        #expect(log.nextBatch() == nil) // The pending edge belongs to the old opt-in generation.
        #expect(guarder.silenceIfMasking(try sineBuffer(), capture: token))
        guarder.flushMaskingDiagnostics()
        let resumed = try #require(log.nextBatch()).events
        #expect(resumed.map(\.name) == [.captureState, .echoGuard])
        #expect(resumed.last?.fields[.masking] == .boolean(true))
        log.setEnabled(false)
        guarder.setReplyAudible(false)
        clock.advance(by: .milliseconds(400))
        #expect(!guarder.silenceIfMasking(try sineBuffer(), capture: token))
        log.setEnabled(true)
        _ = log.nextBatch()
        guarder.flushMaskingDiagnostics()
        #expect(log.nextBatch() == nil) // No activity recorded while off is revived on enable.
        #expect(!guarder.silenceIfMasking(try sineBuffer(), capture: token))
        guarder.flushMaskingDiagnostics()
        #expect(try #require(log.nextBatch()).events.map(\.name) == [.captureState])
        guarder.endMaskingReport(token)
    }

    @Test func reattachingTheSameLogPreservesTheOpenInterval() throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let clock = EchoGuardClock(), log = log(), token = UUID()
        let guarder = AmbientReplyEchoGuard(now: { clock.now })
        guarder.diagnostics = log
        guarder.beginMaskingReport(token, mode: .plain)
        _ = log.nextBatch()
        guarder.setReplyAudible(true)
        #expect(guarder.silenceIfMasking(try sineBuffer(), capture: token))
        clock.advance(by: .seconds(1))
        guarder.diagnostics = log
        #expect(guarder.silenceIfMasking(try sineBuffer(), capture: token))
        guarder.setReplyAudible(false)
        clock.advance(by: .milliseconds(400))
        #expect(!guarder.silenceIfMasking(try sineBuffer(), capture: token))
        guarder.endMaskingReport(token)
        let events = try #require(log.nextBatch()).events
        #expect(events.map(\.name) == [.echoGuard, .echoGuard])
        #expect(events.last?.fields[.ms] == .integer(1_400))
    }
}
