import Foundation
import HailProtocol
import Testing
@testable import HailCore

@MainActor @Suite struct ReplySegmentReviewerProbeTests {
    @Test func privacyToggledMidWindow() async throws {
        let fixture = SegmentWireFixture()
        let socket = try await fixture.connect("main")
        try await fixture.open()
        try await fixture.calibrate()
        fixture.privacy = true
        try await fixture.feed(-20, seconds: 0.3)
        #expect(fixture.controller.lastSegmentYield == nil)
        #expect(fixture.store.segmentWiring?.lastTailRelease == .notAttempted)
        #expect(try await yields(socket).isEmpty)
        await fixture.cleanup()
    }

    @Test func reconnectMidWindowDoesNotSendOnReplacement() async throws {
        let fixture = SegmentWireFixture()
        let old = try await fixture.connect("main")
        try await fixture.open()
        try await fixture.calibrate()
        let generation = fixture.store.snapshots["main"]?.connectionGeneration
        await fixture.store.disconnect("main")
        let replacement = try await fixture.connect("main")
        #expect(fixture.store.snapshots["main"]?.connectionGeneration != generation)
        try await fixture.feed(-20, seconds: 0.3)
        // Flush a main-actor turn and observe the actual asynchronous send attempt.
        for _ in 0..<30 { await Task.yield() }
        #expect(try await yields(old).isEmpty)
        #expect(try await yields(replacement).isEmpty)
        await fixture.cleanup()
    }

    @Test func olderHostKeepsLocalStopWithoutSending() async throws {
        let fixture = SegmentWireFixture()
        let socket = try await fixture.connect("main", capable: false)
        try await fixture.open()
        try await fixture.detect()
        for _ in 0..<30 { await Task.yield() }
        #expect(fixture.controller.lastSegmentYield?.replyID == fixture.reply.id)
        #expect(try await yields(socket).isEmpty)
        await fixture.cleanup()
    }

    @Test func actorRejectsEndpointMismatchEvenWithItsCurrentGeneration() async throws {
        let connector = ScriptedConnector(), socket = ScriptedSocket()
        let endpoint = try endpoint("other")
        await connector.enqueue(.socket(socket), for: endpoint.url)
        let connection = HostConnection(endpoint: endpoint, connector: connector)
        await connection.connect()
        try await waitUntil { await connection.currentSnapshot().state == .negotiating }
        try await socket.push(.hello(HelloInfo(versions: [ProtocolVersion.current],
                                              capabilities: [ReplySegments.capability], deviceName: "Synthetic")))
        try await waitUntil { await connection.currentSnapshot().state == .ready }
        let generation = await connection.currentSnapshot().connectionGeneration
        do {
            try await connection.sendReplyYield(.init(endpointID: "main", replyID: UUID(), segment: 1),
                                                connectionGeneration: generation)
            Issue.record("endpoint mismatch accepted")
        } catch { #expect(error as? HostConnectionFailure == .notReady) }
        #expect(try await yields(socket).isEmpty)
        await connection.disconnect()
    }

    @Test func nextWindowOfOldReplyCannotYieldOnReconnectedGeneration() async throws {
        let fixture = SegmentWireFixture(), timers = ReviewerTimers()
        fixture.controller.idleScheduler = { delay, fire in
            timers.values.append((fixture.clock.now.advanced(by: delay), fire))
            return {}
        }
        let old = try await fixture.connect("main")
        let generation = fixture.store.snapshots["main"]?.connectionGeneration
        try await fixture.open()
        try await fixture.ingest(segmentAudio(fixture.reply, sequence: 1))
        await fixture.store.disconnect("main")
        let replacement = try await fixture.connect("main")
        #expect(fixture.store.snapshots["main"]?.connectionGeneration != generation)
        fixture.clock.advance(by: .seconds(1.5))
        timers.fire(at: fixture.clock.now)
        fixture.player.completeReply()
        try await waitUntil { @MainActor in
            fixture.store.segmentWiring?.captureInput().window != nil && fixture.controller.segmentPause?.segment == 2
        }
        try await fixture.detect()
        for _ in 0..<30 { await Task.yield() }
        #expect(try await yields(old).isEmpty)
        #expect(try await yields(replacement).isEmpty,
                "Old-generation reply must not send reply_yield on the replacement connection")
        #expect(fixture.controller.lastSegmentYield?.replyID == fixture.reply.id) // Local playback still stops.
        let fresh = idleReply()
        try await fixture.ingest(segmentAudio(fresh, sequence: 0))
        fixture.player.completeReply()
        try await waitUntil { @MainActor in
            fixture.controller.segmentPause?.replyID == fresh.id
                && fixture.store.segmentWiring?.captureInput().window != nil
        }
        try await fixture.detect()
        try await waitUntil { try await yields(replacement).count == 1 }
        #expect(try await yields(replacement).first?.payload == .control(.replyYield(reply: fresh.id, segment: 1)))
        await fixture.cleanup()
    }

    @Test func receivedReplyKeepsItsGenerationBeforeItsFirstPlayedWindow() async throws {
        let fixture = SegmentWireFixture()
        let old = try await fixture.connect("main")
        try await fixture.ingest(segmentAudio(fixture.reply, sequence: 0))
        await fixture.store.disconnect("main")
        let replacement = try await fixture.connect("main")
        fixture.player.completeReply()
        try await waitUntil { @MainActor in fixture.store.segmentWiring?.captureInput().window != nil }
        try await fixture.detect()
        for _ in 0..<30 { await Task.yield() }
        #expect(fixture.controller.lastSegmentYield?.replyID == fixture.reply.id)
        #expect(try await yields(old).isEmpty)
        #expect(try await yields(replacement).isEmpty)
        await fixture.cleanup()
    }

    @Test func laterEndpointsAdmissionCannotClearEarlierEndpointsCounter() async throws {
        let fixture = SegmentWireFixture()
        _ = try await fixture.connect("main")
        let other = try await fixture.connect("other")
        try await fixture.open()
        try await fixture.detect()
        // Select/listen to another endpoint while the first onset's five-second deadline remains pending.
        var event = segmentAudio(idleReply(), sequence: 0)
        event.endpointID = "other"
        try await fixture.ingest(event)
        fixture.player.completeReply()
        try await waitUntil { @MainActor in
            fixture.store.segmentWiring?.captureInput().window != nil
                && fixture.controller.segmentPause?.endpointID == "other"
        }
        try await fixture.detect()
        #expect(fixture.guarder.segmentOnsetGate.diagnostics.onsets == 2)
        let before = fixture.store.conversation.entries.count
        try await other.push(.ambientHeard(targetID: "target", text: "Synthetic", turn: nil))
        try await waitUntil { @MainActor in fixture.store.conversation.entries.count > before }
        fixture.clock.advance(by: .seconds(5))
        #expect(fixture.guarder.segmentOnsetGate.diagnostics.withoutAdmittedRequest == 1,
                "An admission from other must leave main's onset pending until expiry")
        await fixture.cleanup()
    }
}

@MainActor private final class ReviewerTimers {
    var values: [(ContinuousClock.Instant, @MainActor () -> Void)] = []
    func fire(at now: ContinuousClock.Instant) {
        let due = values.filter { $0.0 <= now }
        values.removeAll { $0.0 <= now }
        for (_, action) in due { action() }
    }
}

private func yields(_ socket: ScriptedSocket) async throws -> [Frame] {
    try await socket.sentFrames().filter {
        if case .control(.replyYield) = $0.payload { return true }
        return false
    }
}
