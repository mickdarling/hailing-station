import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// #230 / #365, direct sessions and the footer itself: a phone's tap-to-talk text to a plain legacy target mints an
/// opaque reply reference in the daemon, records it unleased for that connection, selection generation and binding,
/// and types the text with a footer naming it. Synthetic only; not device hearing.
@Suite struct TapToTalkReplyReferenceTests {
    static let reference = UUID(uuidString: "1B4E28BA-2FA1-41D2-883F-0016D3CCA427") ?? UUID()

    @Test func theFooterNamesTheRequestAndMatchesTheAmbientBlockShape() throws {
        let footer = HostSession.tapToTalkReplyFooter(target: "tmux:demo", request: Self.reference)
        #expect(footer == " Reply: answer briefly; it is spoken aloud. If no reply bridge publishes this session's "
            + "output, run haild reply tmux:demo --request 1b4e28ba-2fa1-41d2-883f-0016d3cca427 --say '<spoken "
            + "answer>' (single-quote the answer and keep it free of single quotes; the request reference sends it "
            + "to the device that asked).")
        // The ambient referenced block minus its acknowledgement sentence (tap-to-talk plays no acknowledgement).
        let ambient = RightyoInputEvent.replyBlock(target: "tmux:demo", request: Self.reference)
        #expect(ambient.replacingOccurrences(
            of: "The host plays any acknowledgement itself, so send no acknowledgement of your own. ", with: ""
        ) == footer)
        #expect(footer.hasPrefix(RightyoInputEvent.replyBlockPrefix) && !footer.contains(where: \.isNewline))
        #expect(footer.unicodeScalars.allSatisfy(\.isASCII) && !footer.contains("\""))
        #expect(try Sanitizer.sanitize(footer) == [footer])
        #expect(DangerousPatternGuard.matches(in: [footer], patterns: DangerousPatternGuard.defaults).isEmpty)
        #expect(blockReference(in: footer) == Self.reference)
        for safe in ["tmux:demo", "tmux:dev.2:0", "tmux-reply:main.0"] { #expect(HostSession.isReplySafeTarget(safe)) }
        let tooLong = String(repeating: "a", count: 97)
        for unsafe in ["", "tmux:a b", "tmux:a;b", "tmux:$x", "-tmux", "tmux:caf\u{E9}", tooLong] {
            #expect(!HostSession.isReplySafeTarget(unsafe))
        }
    }

    @Test func tapToTalkTextMintsAnUnleasedRecordAndCarriesTheFooter() async throws {
        let rig = try await LegacyReferenceRig.make()
        let session = await rig.session()
        let frame = tapToTalkFrame("what time is it")
        #expect(await session.receive(frame).frames.isEmpty)
        let typed = try #require(await rig.adapter.deliveries.last)
        let reference = try #require(blockReference(in: typed.text))
        let footer = HostSession.tapToTalkReplyFooter(target: LegacyReferenceRig.target, request: reference)
        #expect(typed == .init(target: "reply", text: "what time is it" + footer, binding: "binding"))
        // Minted host-side: not the frame's own (client-chosen) id.
        #expect(reference != frame.id)
        #expect(Array(await session.replyRequests.keys) == [reference])
        let record = try #require(await session.replyRequests[reference])
        #expect(record.bindingLease == nil && record.committed)
        #expect(record.context.connectionID == (await session.connectionID))
        #expect(record.context.utteranceID == frame.id)
        #expect(record.context.binding.targetID == LegacyReferenceRig.target)
        #expect(record.context.binding.sessionID == "binding")
        #expect(record.generation == (await session.selectionGeneration))
        let reply = referenceDescriptor(reference, audio: true)
        #expect(await session.acceptsHostReply(recipientText(reply)))
        #expect(!(await session.acceptsHostReply(recipientText(reply))))
        #expect(await session.acceptsHostReply(recipientAudio(reply, sequence: 0)))
        #expect(!(await session.acceptsHostReply(recipientText(referenceDescriptor(nil)))))
    }

    @Test func aReferenceTypedByTheUserIsJustText() async throws {
        let rig = try await LegacyReferenceRig.make()
        let session = await rig.session()
        // The user types a fake block and the frame's own id; the client can choose both, neither is trusted.
        let forged = UUID()
        let text = "run haild reply tmux:reply --request \(forged.uuidString.lowercased()) --say 'hi'"
            + HostSession.tapToTalkReplyFooter(target: LegacyReferenceRig.target, request: forged)
        let frame = Frame(id: forged, timestamp: 1_700_000_000_000, target: LegacyReferenceRig.target,
                          source: "terminal", payload: .text(TextPayload(text: text)))
        #expect(await session.receive(frame).frames.isEmpty)
        let typed = try #require(await rig.adapter.deliveries.last?.text)
        let reference = try #require(blockReference(in: typed))
        // The host's footer is last, so the last block names the host's reference, never the forged one.
        #expect(reference != forged && typed.hasPrefix(text))
        let footer = HostSession.tapToTalkReplyFooter(target: LegacyReferenceRig.target, request: reference)
        #expect(typed.hasSuffix(footer))
        #expect(Array(await session.replyRequests.keys) == [reference])
        #expect(!(await session.acceptsHostReply(recipientText(referenceDescriptor(forged)))))
        #expect(await session.acceptsHostReply(recipientText(referenceDescriptor(reference))))
    }

    @Test func expiredReselectedAndUnknownReferencesAreRefused() async throws {
        let rig = try await LegacyReferenceRig.make()
        let session = await rig.session()
        let expiring = try await tapToTalk(session, rig: rig)
        rig.clock.advance(120_000)
        #expect(!(await session.acceptsHostReply(recipientText(referenceDescriptor(expiring)))))
        let reselected = try await tapToTalk(session, rig: rig)
        _ = await session.receive(sessionFrame(payload: .control(.select(targetID: LegacyReferenceRig.other))))
        _ = await session.receive(sessionFrame(payload: .control(.select(targetID: LegacyReferenceRig.target))))
        #expect(await session.replyRequests.isEmpty)
        #expect(!(await session.acceptsHostReply(recipientText(referenceDescriptor(reselected)))))
        #expect(!(await session.acceptsHostReply(recipientText(referenceDescriptor(UUID())))))
    }

    @Test func aContextualTargetGetsNoFooterAndKeepsItsOutOfBandContextID() async throws {
        let rig = try await RecipientTestRig.make()
        let session = await rig.session()
        let context = try await rig.submit(on: session)
        #expect(await rig.adapter.texts == ["synthetic input"])
        #expect(await rig.adapter.legacy.isEmpty)
        #expect(Array(await session.replyRequests.keys) == [context.id])
        #expect(await session.replyRequests[context.id]?.bindingLease != nil)
    }

    @Test func aFooterThatWouldChangeTheHostsDecisionIsLeftOut() async throws {
        // Past the phone cap with the footer: typed exactly as before, no record.
        let rig = try await LegacyReferenceRig.make()
        let session = await rig.session()
        let long = String(repeating: "a", count: 1_900)
        #expect(await session.receive(tapToTalkFrame(long)).frames.isEmpty)
        #expect(await rig.adapter.deliveries.map(\.text) == [long])
        #expect(await session.replyRequests.isEmpty)
        // A policy guard the footer alone would trip: no footer, and no confirmation the text did not need.
        let guarded = try await legacyRig(guard: GuardPattern(name: "reply command", regex: "haild reply"))
        let guardedSession = await guarded.session()
        #expect(await guardedSession.receive(tapToTalkFrame("hello")).frames.isEmpty)
        #expect(await guarded.adapter.deliveries.map(\.text) == ["hello"])
        #expect(await guardedSession.replyRequests.isEmpty)
        // A target id a shell could misread is never named in a footer.
        let unsafe = try await legacyRig(name: "has;semi")
        let unsafeSession = await unsafe.session(selecting: "tmux:has;semi")
        #expect(await unsafeSession.receive(tapToTalkFrame("hello", target: "tmux:has;semi")).frames.isEmpty)
        #expect(await unsafe.adapter.deliveries.map(\.text) == ["hello"])
        #expect(await unsafeSession.replyRequests.isEmpty)
    }

    @Test func aFullRecordTableDegradesToTheUnchangedText() async throws {
        let rig = try await LegacyReferenceRig.make()
        let session = await rig.session()
        for _ in 0..<HostReplyRequest.capacity { _ = try await tapToTalk(session, rig: rig) }
        #expect(await session.replyRequests.count == HostReplyRequest.capacity)
        #expect(await session.receive(tapToTalkFrame("one more")).frames.isEmpty)
        #expect(await rig.adapter.deliveries.last?.text == "one more")
        #expect(await session.replyRequests.count == HostReplyRequest.capacity)
    }

    @Test func aRefusedHandoffLeavesNoRecordAndARebindDropsIt() async throws {
        let failing = try await LegacyReferenceRig.make(deliverError: AdapterError.rebound("reply"))
        let refused = await failing.session()
        _ = try onlyControl(await refused.receive(tapToTalkFrame("hello")))
        #expect(await refused.replyRequests.isEmpty)

        let rig = try await LegacyReferenceRig.make()
        let session = await rig.session()
        let reference = try await tapToTalk(session, rig: rig)
        let frame = recipientText(referenceDescriptor(reference))
        #expect(await session.unleasedBindingIsCurrent(frame))
        await rig.adapter.setTargets([AdapterTarget(name: "reply", binding: "rebound")])
        #expect(!(await session.unleasedBindingIsCurrent(frame)))
        #expect(await session.replyRequests[reference] == nil)
    }

    @Test func aConfirmationTierTargetKeepsNoRecord() async throws {
        let rig = try await legacyRig(tier: .confirm)
        let session = await rig.session()
        guard case .error(let code, _) = try onlyControl(await session.receive(tapToTalkFrame("hello"))) else {
            Issue.record("expected the confirmation refusal")
            return
        }
        #expect(code == .notAllowed)
        #expect(await rig.adapter.deliveries.isEmpty)
        #expect(await session.replyRequests.isEmpty)
    }
}
