import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// #230, direct sessions and the block itself: an ambient dispatch to a legacy adapter mints an opaque reply
/// reference bound host-side to the dispatching connection, its selection generation and the exact binding.
/// Synthetic only; not device hearing.
@Suite struct AmbientReplyReferenceTests {
    static let reference = UUID(uuidString: "1B4E28BA-2FA1-41D2-883F-0016D3CCA427") ?? UUID()

    @Test func theReferencedBlockNamesTheRequestAndKeepsTheBlockShape() throws {
        let block = RightyoInputEvent.replyBlock(target: "tmux:demo", request: Self.reference)
        #expect(block == " Reply: answer briefly; it is spoken aloud. The host plays any acknowledgement itself, so "
            + "send no acknowledgement of your own. If no reply bridge publishes this session's output, run haild "
            + "reply tmux:demo --request 1b4e28ba-2fa1-41d2-883f-0016d3cca427 --say '<spoken answer>' (single-quote "
            + "the answer and keep it free of single quotes; the request reference sends it to the device that asked).")
        #expect(block.hasPrefix(RightyoInputEvent.replyBlockPrefix) && !block.contains(where: \.isNewline))
        #expect(block.unicodeScalars.allSatisfy(\.isASCII) && !block.contains("\""))
        #expect(!RightyoInputEvent.carriesMarker(block))
        #expect(try Sanitizer.sanitize(block) == [block])
        #expect(DangerousPatternGuard.matches(in: [block], patterns: DangerousPatternGuard.defaults).isEmpty)
        // The request-less block is unchanged byte for byte.
        #expect(RightyoInputEvent.replyBlock(target: "tmux:demo", request: nil)
            == RightyoInputEvent.replyBlock(target: "tmux:demo"))
        #expect(blockReference(in: block) == Self.reference)
    }

    @Test func onlyThePromptsOwnTrailingBlockIsRewritten() {
        let plain = RightyoInputEvent.replyBlock(target: "tmux:demo")
        let referenced = RightyoInputEvent.replyBlock(target: "tmux:demo", request: Self.reference)
        let body = "Owner asked: caf\u{E9} \u{1F600} {\"x\":1}"
        #expect(RightyoInputEvent.referencing(body + plain, target: "tmux:demo", request: Self.reference)
            == body + referenced)
        // Another target's block, a block that is not last, or no block at all: nothing is rewritten.
        #expect(RightyoInputEvent.referencing(body + plain, target: "tmux:other", request: Self.reference) == nil)
        #expect(RightyoInputEvent.referencing(plain + body, target: "tmux:demo", request: Self.reference) == nil)
        #expect(RightyoInputEvent.referencing(body, target: "tmux:demo", request: Self.reference) == nil)
        // A prompt the longer block would push past the dispatch cap keeps its request-less block.
        let filler = String(repeating: "a", count: LocalDispatchRequest.maxTextBytes - plain.utf8.count)
        #expect((filler + plain).utf8.count == LocalDispatchRequest.maxTextBytes)
        #expect(RightyoInputEvent.referencing(filler + plain, target: "tmux:demo", request: Self.reference) == nil)
    }

    @Test func aReferenceOnALegacyAdapterMintsAnUnleasedRecordForThisConnection() async throws {
        let rig = try await LegacyReferenceRig.make()
        let session = await rig.session()
        let owner = try await LegacyReferenceRig.dispatch(session, reference: Self.reference)
        #expect(owner == Self.reference)
        // The literal text went the legacy way, pinned to the listed binding.
        #expect(await rig.adapter.deliveries == [.init(target: "reply", text: LegacyReferenceRig.prompt,
                                                       binding: "binding")])
        let record = try #require(await session.replyRequests[Self.reference])
        #expect(record.bindingLease == nil && record.committed)
        #expect(record.context.connectionID == (await session.connectionID))
        #expect(record.context.binding.targetID == LegacyReferenceRig.target)
        #expect(record.context.binding.sessionID == "binding")
        #expect(record.generation == (await session.selectionGeneration))
        // A reply naming it is accepted once for text; the wrong target never is.
        let reply = referenceDescriptor(Self.reference, audio: true)
        #expect(await session.acceptsHostReply(recipientText(reply)))
        #expect(!(await session.acceptsHostReply(recipientText(reply))))
        #expect(await session.acceptsHostReply(recipientAudio(reply, sequence: 0)))
        #expect(await session.acceptsHostReply(recipientAudio(reply, sequence: 1, final: true)))
        let elsewhere = referenceDescriptor(Self.reference, target: LegacyReferenceRig.other)
        #expect(!(await session.acceptsHostReply(recipientText(elsewhere))))
    }

    @Test func expiredSelectedAwayAndUnknownReferencesAreRefused() async throws {
        let rig = try await LegacyReferenceRig.make()
        let session = await rig.session()
        let expiring = try #require(try await LegacyReferenceRig.dispatch(session, reference: UUID()))
        rig.clock.advance(120_000)
        #expect(!(await session.acceptsHostReply(recipientText(referenceDescriptor(expiring)))))
        let reselected = try #require(try await LegacyReferenceRig.dispatch(session, reference: UUID()))
        _ = await session.receive(sessionFrame(payload: .control(.select(targetID: LegacyReferenceRig.other))))
        _ = await session.receive(sessionFrame(payload: .control(.select(targetID: LegacyReferenceRig.target))))
        // Reselecting the same target never revives a request minted under the old selection.
        #expect(await session.replyRequests.isEmpty)
        #expect(!(await session.acceptsHostReply(recipientText(referenceDescriptor(reselected)))))
        #expect(!(await session.acceptsHostReply(recipientText(referenceDescriptor(UUID())))))
        #expect(!(await session.acceptsHostReply(recipientText(referenceDescriptor(nil)))))
    }

    @Test func withoutAReferenceLocalDispatchStillOwnsNothing() async throws {
        let rig = try await LegacyReferenceRig.make()
        let session = await rig.session()
        // The local socket's dispatch (no bound reference) stays request-less and its text is unchanged. A phone's
        // text frame now mints its own tap-to-talk reference (TapToTalkReplyReferenceTests).
        #expect(try await session.dispatch(LegacyReferenceRig.request(connection: UUID())) == nil)
        #expect(await rig.adapter.deliveries.map(\.text) == [LegacyReferenceRig.prompt])
        #expect(await session.replyRequests.isEmpty)
    }

    @Test func aRefusedHandoffLeavesNoRecordAndARebindDropsIt() async throws {
        let failing = try await LegacyReferenceRig.make(deliverError: AdapterError.rebound("reply"))
        let refused = await failing.session()
        await #expect(throws: LocalDispatchRefusal.deliveryRefused) {
            try await LegacyReferenceRig.dispatch(refused, reference: UUID())
        }
        #expect(await refused.replyRequests.isEmpty)

        let rig = try await LegacyReferenceRig.make()
        let session = await rig.session()
        let owner = try #require(try await LegacyReferenceRig.dispatch(session, reference: UUID()))
        let frame = recipientText(referenceDescriptor(owner))
        #expect(await session.unleasedBindingIsCurrent(frame))
        // The pane behind the name changed: the unleased record cannot follow it.
        await rig.adapter.setTargets([AdapterTarget(name: "reply", binding: "rebound")])
        #expect(!(await session.unleasedBindingIsCurrent(frame)))
        #expect(await session.replyRequests[owner] == nil)
        #expect(!(await session.acceptsHostReply(frame)))
    }

    @Test func aReferenceAlreadyHeldIsNeverOverwritten() async throws {
        let rig = try await LegacyReferenceRig.make()
        let session = await rig.session()
        _ = try #require(try await LegacyReferenceRig.dispatch(session, reference: Self.reference))
        let before = try #require(await session.replyRequests[Self.reference])
        await #expect(throws: LocalDispatchRefusal.deliveryRefused) {
            try await LegacyReferenceRig.dispatch(session, reference: Self.reference)
        }
        #expect(await rig.adapter.deliveries.count == 1)
        #expect(await session.replyRequests[Self.reference]?.context == before.context)
    }
}
