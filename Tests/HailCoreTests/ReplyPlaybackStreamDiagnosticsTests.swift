import Foundation
@testable import HailCore
import HailProtocol
import Testing

/// #1227: accepted audio and scheduling state at abandonment, using only the rig's manual clock.
@MainActor
@Suite struct ReplyPlaybackStreamDiagnosticsTests {
    let suite = "hail-stream-diagnostics-\(UUID().uuidString)"
    var defaults: UserDefaults { UserDefaults(suiteName: suite) ?? .standard }

    func watch(_ rig: IdleRig) -> DeviceDiagnostics {
        // The production watch defaults to the real clock; align it with this rig before any frames arrive.
        rig.controller.idleWatch.aheadUntil = rig.controller.idleNow()
        let log = DeviceDiagnostics(defaults: defaults, appInfo: [:], wallNow: { 1 })
        log.setEnabled(true)
        _ = log.nextBatch()
        log.watch(rig.controller)
        return log
    }

    func abandonment(_ log: DeviceDiagnostics) throws -> DiagnosticEvent {
        let errors = (log.nextBatch()?.events ?? []).filter { $0.fields[.code] == .token("stream_abandoned") }
        #expect(errors.count == 1)
        return try #require(errors.first)
    }

    @Test func aGapReportsLastArrivalFirstMissingAndSchedulingCounts() throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let rig = IdleRig(), reply = idleReply()
        let log = watch(rig)
        rig.controller.ingest(firstAudioText(reply))
        // Last arrival differs from the highest sequence; the final marker arrived beyond a gap.
        for sequence in [0, 4, 2] {
            rig.controller.ingest(idleAudio(reply, sequence: sequence, final: sequence == 4, byte: 7))
        }
        rig.advance(by: .seconds(22))
        let event = try abandonment(log)
        #expect(event.fields == [
            .code: .token("stream_abandoned"), .ms: .integer(20_000),
            .lastSequence: .integer(2), .expectedSequence: .integer(1), .gap: .boolean(true),
            .receivedFrames: .integer(3), .scheduledFrames: .integer(1), .terminal: .boolean(true),
            .lastFrameMs: .integer(21_300)
        ])
        #expect(rig.controller.streamReceipts.isEmpty)
        // Only these fixed fields and scalar kinds leave the controller, never payload bytes or identifiers.
        let encoded = try JSONEncoder().encode(event)
        let text = try #require(String(data: encoded, encoding: .utf8))
        #expect(!text.contains(reply.id.uuidString.lowercased()))
        #expect(!text.contains(reply.hostID))
        #expect(!text.contains(reply.targetID))
        #expect(!text.contains("Synthetic reply"))
    }

    @Test func contiguousAudioWithoutATerminalReportsFalseAndActualFrameAge() throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let rig = IdleRig(), reply = idleReply()
        let log = watch(rig)
        rig.controller.ingest(idleAudio(reply, sequence: 0, final: false, byte: 7))
        rig.advance(by: .seconds(5))
        rig.controller.ingest(idleAudio(reply, sequence: 1, final: false, byte: 8))
        rig.advance(by: .seconds(22))
        let fields = try abandonment(log).fields
        #expect(fields[.gap] == .boolean(false))
        #expect(fields[.expectedSequence] == .integer(2))
        #expect(fields[.lastSequence] == .integer(1))
        #expect(fields[.terminal] == .boolean(false))
        #expect(fields[.receivedFrames] == .integer(2))
        #expect(fields[.scheduledFrames] == .integer(2))
        #expect(fields[.lastFrameMs] == .integer(21_300))
    }

    @Test func missingSequenceZeroIsAGapWithNothingScheduled() throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let rig = IdleRig(), reply = idleReply()
        let log = watch(rig)
        rig.controller.ingest(idleAudio(reply, sequence: 3, final: true, byte: 7))
        rig.advance(by: .seconds(20))
        let fields = try abandonment(log).fields
        #expect(fields[.lastSequence] == .integer(3))
        #expect(fields[.expectedSequence] == .integer(0))
        #expect(fields[.gap] == .boolean(true))
        #expect(fields[.receivedFrames] == .integer(1))
        #expect(fields[.scheduledFrames] == .integer(0))
        #expect(fields[.terminal] == .boolean(true))
        #expect(fields[.lastFrameMs] == .integer(20_000))
    }

    @Test func filledGapsAndDuplicatesDoNotInflateReceivedOrScheduledCounts() throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let rig = IdleRig(), reply = idleReply()
        let log = watch(rig)
        for sequence in [0, 2, 1, 1] {
            rig.controller.ingest(idleAudio(reply, sequence: sequence, final: false, byte: 7))
        }
        rig.advance(by: .seconds(24))
        let fields = try abandonment(log).fields
        #expect(fields[.gap] == .boolean(false))
        #expect(fields[.expectedSequence] == .integer(3))
        #expect(fields[.lastSequence] == .integer(1))
        #expect(fields[.receivedFrames] == .integer(3))
        #expect(fields[.scheduledFrames] == .integer(3))
    }

    @Test func completedStreamsNeverAbandonEvenWhenThePlayerStalls() {
        defer { defaults.removePersistentDomain(forName: suite) }
        let rig = IdleRig(), reply = idleReply()
        let log = watch(rig)
        rig.controller.ingest(idleAudio(reply, sequence: 1, final: true, byte: 8))
        rig.controller.ingest(idleAudio(reply, sequence: 0, final: false, byte: 7))
        rig.advance(by: .seconds(300))
        #expect(rig.controller.isReplyAudioOutputBusy)
        #expect(!(log.nextBatch()?.events ?? []).contains { $0.fields[.code] == .token("stream_abandoned") })
        rig.player.completeReply()
        #expect(rig.controller.streamReceipts.isEmpty)
        rig.advance(by: .seconds(300))
        #expect(!(log.nextBatch()?.events ?? []).contains { $0.fields[.code] == .token("stream_abandoned") })
    }

    @Test func anotherRepliesFirstAudioTimeoutCannotBorrowTheHeadsFields() throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let rig = IdleRig(), active = idleReply(), silent = idleReply()
        let log = watch(rig)
        rig.controller.ingest(idleAudio(active, sequence: 0, final: false, byte: 7))
        rig.controller.ingest(firstAudioText(silent, endpoint: "other"))
        rig.advance(by: .seconds(10))
        rig.controller.ingest(idleAudio(active, sequence: 1, final: false, byte: 8))
        rig.advance(by: .seconds(10))
        #expect(try abandonment(log).fields == [.code: .token("stream_abandoned"), .ms: .integer(20_000)])
    }

    @Test func refusedConflictingAudioDoesNotRefreshArrivalOrClaimATerminal() throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let rig = IdleRig(), reply = idleReply()
        let log = watch(rig)
        rig.controller.ingest(idleAudio(reply, sequence: 0, final: false, byte: 7))
        rig.advance(by: .seconds(5))
        rig.controller.ingest(idleAudio(reply, sequence: 0, final: true, byte: 8))
        rig.advance(by: .seconds(17))
        let fields = try abandonment(log).fields
        #expect(fields[.terminal] == .boolean(false))
        #expect(fields[.receivedFrames] == .integer(1))
        #expect(fields[.scheduledFrames] == .integer(1))
        #expect(fields[.lastFrameMs] == .integer(21_300))
    }

    @Test func supersedingAPausedStreamKeepsOnlyTheNewReceipt() {
        let rig = IdleRig()
        rig.controller.ingest(idleAudio(idleReply(), sequence: 0, final: false, byte: 7))
        rig.controller.togglePause()
        let replacement = idleReply()
        rig.controller.ingest(idleAudio(replacement, sequence: 0, final: true, byte: 8))
        #expect(rig.controller.streamReceipts.count == 1)
        #expect(rig.controller.streamReceipts.keys.first?.replyID == replacement.id)
        rig.player.completeReply()
        #expect(rig.controller.streamReceipts.isEmpty)
    }

    @Test func queuedStreamsKeepTheirOwnArrivalAgeAndStopRetiresReceipts() throws {
        defer { defaults.removePersistentDomain(forName: suite) }
        let rig = IdleRig(), ahead = idleReply(), queued = idleReply()
        let log = watch(rig)
        rig.controller.ingest(idleAudio(ahead, sequence: 0, final: true, byte: 7))
        rig.controller.ingest(idleAudio(queued, sequence: 0, final: false, byte: 8))
        rig.advance(by: .seconds(30))
        rig.player.completeReply()
        rig.advance(by: .seconds(22))
        #expect(try abandonment(log).fields[.lastFrameMs] == .integer(51_300))
        rig.controller.ingest(idleAudio(idleReply(), sequence: 0, final: false, byte: 9))
        rig.controller.stopPlayback(from: nil)
        #expect(rig.controller.streamReceipts.isEmpty)
    }
}
