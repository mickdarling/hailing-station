import Foundation
import HailProtocol
import Observation
import Synchronization
import Testing
@testable import HailCore

@MainActor @Suite struct ReplySegmentWiringScopeTests {
    @Test(arguments: ["same", "other-B", "other-A", "reconnect"])
    func aThenBAdmissionKeepsIndependentDeadlines(_ mode: String) async throws {
        let fixture = SegmentWireFixture()
        let main = try await fixture.connect("main")
        let other = try await fixture.connect("other")
        try await fixture.open()
        let scopeA = try #require(fixture.store.segmentWiring?.captureInput().scope)
        try await fixture.detect() // A onset at 0.9 s, expires at 5.9 s.
        var admissionSocket = main
        var event = segmentAudio(idleReply(), sequence: 0)
        if mode.hasPrefix("other") {
            event.endpointID = "other"
            if mode == "other-B" { admissionSocket = other }
        }
        if mode == "reconnect" {
            await fixture.store.disconnect("main")
            admissionSocket = try await fixture.connect("main")
        }
        try await fixture.ingest(event)
        fixture.player.completeReply()
        try await waitUntil { @MainActor in fixture.controller.segmentPause?.replyID == event.frame.replyID }
        try await waitUntil { @MainActor in fixture.store.segmentWiring?.captureInput().window != nil }
        let scopeB = try #require(fixture.store.segmentWiring?.captureInput().scope)
        #expect((scopeA == scopeB) == (mode == "same"))
        try await fixture.detect() // B onset at 1.8 s, expires at 6.8 s.
        #expect(fixture.guarder.segmentOnsetGate.diagnostics.onsets == 2)
        let before = fixture.store.conversation.entries.count
        try await admissionSocket.push(.ambientHeard(targetID: "target", text: "Synthetic", turn: nil))
        try await waitUntil { @MainActor in fixture.store.conversation.entries.count > before }
        fixture.clock.advance(by: .milliseconds(4_100))
        #expect(fixture.guarder.segmentOnsetGate.diagnostics.withoutAdmittedRequest ==
                (mode == "other-B" || mode == "reconnect" ? 1 : 0))
        fixture.clock.advance(by: .milliseconds(900))
        #expect(fixture.guarder.segmentOnsetGate.diagnostics.withoutAdmittedRequest == 1)
        await fixture.cleanup()
    }

    @Test func replayOfIdenticalYieldPublishesDistinctObservableEvents() async throws {
        let fixture = SegmentWireFixture()
        _ = try await fixture.connect("main", capable: false) // Event follows local success, independently of send.
        try await prepareReplay(fixture)
        fixture.controller.replayLatest()
        fixture.player.completeReply()
        try await waitUntil { @MainActor in fixture.store.segmentWiring?.captureInput().window != nil }
        let observed = Mutex(0)
        withObservationTracking { _ = fixture.store.segmentYieldEvent } onChange: {
            observed.withLock { $0 += 1 }
        }
        try await fixture.detect()
        let first = try #require(fixture.store.segmentYieldEvent)
        #expect(first.id == 1)
        #expect(first.endpointID == "main")
        #expect(first.replyID == fixture.reply.id)
        #expect(first.segment == 1)
        #expect(observed.withLock { $0 } == 1)
        fixture.controller.replayLatest()
        fixture.player.completeReply() // Replay marker actually played.
        try await waitUntil { @MainActor in fixture.store.segmentWiring?.captureInput().window != nil }
        withObservationTracking { _ = fixture.store.segmentYieldEvent } onChange: {
            observed.withLock { $0 += 1 }
        }
        try await fixture.detect()
        let second = try #require(fixture.store.segmentYieldEvent)
        #expect(second.id == first.id + 1)
        #expect(second.endpointID == first.endpointID)
        #expect(second.replyID == first.replyID)
        #expect(second.segment == first.segment)
        #expect(observed.withLock { $0 } == 2)
        #expect(second != first)
        fixture.privacy = true
        fixture.store.segmentWiring?.onset() // Closed/unauthorized onset cannot publish another event.
        #expect(fixture.store.segmentYieldEvent == second)
        await fixture.cleanup()
    }

    private func prepareReplay(_ fixture: SegmentWireFixture) async throws {
        try await fixture.open()
        try await fixture.ingest(idleAudio(fixture.reply, sequence: 1, final: true, byte: 9))
        fixture.advance(by: .seconds(1.5))
        fixture.player.completeReply()
        #expect(fixture.controller.lastKey?.replyID == fixture.reply.id)
        try await waitUntil { @MainActor in fixture.store.segmentWiring?.captureInput().window == nil }
    }
}

private extension Frame {
    var replyID: UUID? {
        if case .audio(let audio) = payload { return audio.reply?.id }
        return nil
    }
}
