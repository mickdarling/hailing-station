import Foundation
import HailProtocol
import Testing
@testable import HailCore

@MainActor @Suite struct ReplySegmentReviewerProbeTests {
    @Test func privacyToggledMidWindow() async throws {
        let f = SegmentWireFixture()
        let socket = try await f.connect("main")
        try await f.open()
        try await f.calibrate()
        f.privacy = true
        try await f.feed(-20, seconds: 0.3)
        #expect(f.controller.lastSegmentYield == nil)
        #expect(f.store.segmentWiring?.lastTailReleased == nil)
        #expect(try await yields(socket).isEmpty)
        await f.cleanup()
    }

    @Test func reconnectMidWindowDoesNotSendOnReplacement() async throws {
        let f = SegmentWireFixture()
        let old = try await f.connect("main")
        try await f.open()
        try await f.calibrate()
        let generation = f.store.snapshots["main"]?.connectionGeneration
        await f.store.disconnect("main")
        let replacement = try await f.connect("main")
        #expect(f.store.snapshots["main"]?.connectionGeneration != generation)
        try await f.feed(-20, seconds: 0.3)
        // Flush a main-actor turn and observe the actual asynchronous send attempt.
        for _ in 0..<30 { await Task.yield() }
        #expect(try await yields(old).isEmpty)
        #expect(try await yields(replacement).isEmpty)
        await f.cleanup()
    }

    @Test func olderHostKeepsLocalStopWithoutSending() async throws {
        let f = SegmentWireFixture()
        let socket = try await f.connect("main", capable: false)
        try await f.open()
        try await f.detect()
        for _ in 0..<30 { await Task.yield() }
        #expect(f.controller.lastSegmentYield?.replyID == f.reply.id)
        #expect(try await yields(socket).isEmpty)
        await f.cleanup()
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
        let f = SegmentWireFixture(), timers = ReviewerTimers()
        f.controller.idleScheduler = { delay, fire in
            timers.values.append((f.clock.now.advanced(by: delay), fire))
            return {}
        }
        let old = try await f.connect("main")
        let generation = f.store.snapshots["main"]?.connectionGeneration
        try await f.open()
        try await f.ingest(segmentAudio(f.reply, sequence: 1))
        await f.store.disconnect("main")
        let replacement = try await f.connect("main")
        #expect(f.store.snapshots["main"]?.connectionGeneration != generation)
        f.clock.advance(by: .seconds(1.5))
        timers.fire(at: f.clock.now)
        f.player.completeReply()
        try await waitUntil { @MainActor in
            f.store.segmentWiring?.captureInput().window != nil && f.controller.segmentPause?.segment == 2
        }
        try await f.detect()
        for _ in 0..<30 { await Task.yield() }
        #expect(try await yields(old).isEmpty)
        #expect(try await yields(replacement).isEmpty,
                "Old-generation reply must not send reply_yield on the replacement connection")
        #expect(f.controller.lastSegmentYield?.replyID == f.reply.id) // Local playback still stops.
        let fresh = idleReply()
        try await f.ingest(segmentAudio(fresh, sequence: 0))
        f.player.completeReply()
        try await waitUntil { @MainActor in
            f.controller.segmentPause?.replyID == fresh.id && f.store.segmentWiring?.captureInput().window != nil
        }
        try await f.detect()
        try await waitUntil { try await yields(replacement).count == 1 }
        #expect(try await yields(replacement).first?.payload == .control(.replyYield(reply: fresh.id, segment: 1)))
        await f.cleanup()
    }

    @Test func receivedReplyKeepsItsGenerationBeforeItsFirstPlayedWindow() async throws {
        let f = SegmentWireFixture()
        let old = try await f.connect("main")
        try await f.ingest(segmentAudio(f.reply, sequence: 0))
        await f.store.disconnect("main")
        let replacement = try await f.connect("main")
        f.player.completeReply()
        try await waitUntil { @MainActor in f.store.segmentWiring?.captureInput().window != nil }
        try await f.detect()
        for _ in 0..<30 { await Task.yield() }
        #expect(f.controller.lastSegmentYield?.replyID == f.reply.id)
        #expect(try await yields(old).isEmpty)
        #expect(try await yields(replacement).isEmpty)
        await f.cleanup()
    }

    @Test func laterEndpointsAdmissionCannotClearEarlierEndpointsCounter() async throws {
        let f = SegmentWireFixture()
        _ = try await f.connect("main")
        let other = try await f.connect("other")
        try await f.open()
        try await f.detect()
        // Select/listen to another endpoint while the first onset's five-second deadline remains pending.
        var event = segmentAudio(idleReply(), sequence: 0)
        event.endpointID = "other"
        try await f.ingest(event)
        f.player.completeReply()
        try await waitUntil { @MainActor in
            f.store.segmentWiring?.captureInput().window != nil && f.controller.segmentPause?.endpointID == "other"
        }
        try await f.detect()
        #expect(f.guarder.segmentOnsetGate.diagnostics.onsets == 2)
        let before = f.store.conversation.entries.count
        try await other.push(.ambientHeard(targetID: "target", text: "Synthetic", turn: nil))
        try await waitUntil { @MainActor in f.store.conversation.entries.count > before }
        f.clock.advance(by: .seconds(5))
        #expect(f.guarder.segmentOnsetGate.diagnostics.withoutAdmittedRequest == 1,
                "An admission from other must leave main's onset pending until expiry")
        await f.cleanup()
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
