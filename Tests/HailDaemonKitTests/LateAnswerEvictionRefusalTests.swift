import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// #723: a request that evicted a late record at capacity and is then refused before it commits gives that record
/// back; a committed one keeps the eviction. Synthetic adapter and clock only.
@Suite struct LateAnswerEvictionRefusalTests {
    private static let minute: Int64 = 60_000

    /// A full session whose records are all late, the oldest first.
    private func fullOfLateRecords(_ rig: RecipientTestRig) async throws -> (HostSession, [ProviderTurnContext]) {
        let session = await rig.session()
        var contexts: [ProviderTurnContext] = []
        for _ in 0..<HostReplyRequest.capacity {
            contexts.append(try await rig.submit(on: session))
            rig.clock.advance(1)
        }
        rig.clock.advance(5 * Self.minute)
        return (session, contexts)
    }

    private func status(_ session: HostSession, _ context: ProviderTurnContext) async -> ReplyPublicationStatus {
        await session.replyPublicationStatus(recipientText(recipientDescriptor(context)))
    }

    @Test func aRequestThatNeedsConfirmationGivesTheEvictedRecordBack() async throws {
        let rig = try await RecipientTestRig.make()
        let (session, contexts) = try await fullOfLateRecords(rig)
        await #expect(throws: LocalDispatchRefusal.confirmationRequired) {
            try await session.dispatch(dispatchRequest(connection: UUID(), text: "synthetic guarded command"))
        }
        #expect(await status(session, contexts[0]) == .ready)
        #expect(await session.replyRequests.count == HostReplyRequest.capacity)
        #expect(await session.evictedForHandoff.isEmpty)
    }

    @Test func aFailedHandoffGivesTheEvictedRecordBack() async throws {
        let rig = try await RecipientTestRig.make()
        let (session, contexts) = try await fullOfLateRecords(rig)
        await rig.adapter.failHandoff()
        let refused = await session.receive(
            sessionFrame(target: RecipientTestRig.target, payload: .text(TextPayload(text: "synthetic input")))
        )
        #expect(!refused.frames.isEmpty)
        #expect(await status(session, contexts[0]) == .ready)
        #expect(await session.replyRequests.count == HostReplyRequest.capacity)
        #expect(await session.evictedForHandoff.isEmpty)
    }

    @Test func aCommittedRequestKeepsTheEviction() async throws {
        let rig = try await RecipientTestRig.make()
        let (session, contexts) = try await fullOfLateRecords(rig)
        let next = try await rig.submit(on: session)
        #expect(await status(session, next) == .ready)
        #expect(await status(session, contexts[0]) == .absent)
        #expect(await session.evictedForHandoff.isEmpty)
    }

    /// Held past its own 120 s, the new request's commit is refused (`commit`'s authority-and-lifetime branch).
    @Test func aCommitRefusedAfterTheHandoffGivesTheEvictedRecordBack() async throws {
        let rig = try await RecipientTestRig.make()
        let (session, contexts) = try await fullOfLateRecords(rig)
        let next = try await heldHandoff(rig, session) { rig.clock.advance(3 * Self.minute) }
        #expect(await status(session, next) == .absent)
        #expect(await status(session, contexts[0]) == .ready)
        #expect(await session.evictedForHandoff.isEmpty)
    }

    @Test func anEvictedRecordThatExpiredMeanwhileIsNotGivenBack() async throws {
        let rig = try await RecipientTestRig.make()
        let (session, contexts) = try await fullOfLateRecords(rig)
        _ = try await heldHandoff(rig, session) { rig.clock.advance(26 * Self.minute) }
        #expect(!(await session.replyRequests.keys.contains(contexts[0].id)))
        #expect(await session.evictedForHandoff.isEmpty)
    }

    /// Submits one input whose handoff is held while `during` runs, and returns its context.
    private func heldHandoff(
        _ rig: RecipientTestRig, _ session: HostSession, during: () async -> Void
    ) async throws -> ProviderTurnContext {
        await rig.adapter.holdHandoff()
        let delivery = Task {
            await session.receive(sessionFrame(
                target: RecipientTestRig.target, payload: .text(TextPayload(text: "synthetic input"))
            ))
        }
        await rig.adapter.waitForHandoff()
        let context = try #require(await rig.adapter.contexts.last)
        await during()
        await rig.adapter.releaseHandoff()
        _ = await delivery.value
        return context
    }

    @Test func aSelectionChangeDuringTheHandoffRestoresNothing() async throws {
        let rig = try await RecipientTestRig.make()
        let (session, contexts) = try await fullOfLateRecords(rig)
        await rig.adapter.holdHandoff()
        let delivery = Task {
            await session.receive(sessionFrame(
                target: RecipientTestRig.target, payload: .text(TextPayload(text: "synthetic input"))
            ))
        }
        await rig.adapter.waitForHandoff()
        _ = await session.receive(sessionFrame(payload: .control(.select(targetID: "recipient:other"))))
        _ = await session.receive(sessionFrame(payload: .control(.select(targetID: RecipientTestRig.target))))
        await rig.adapter.releaseHandoff()
        _ = await delivery.value
        // The old selection's records are gone, and the evicted one is not revived under the new selection.
        #expect(await status(session, contexts[0]) == .absent)
        #expect(await session.replyRequests.isEmpty)
        #expect(await session.evictedForHandoff.isEmpty)
    }
}
