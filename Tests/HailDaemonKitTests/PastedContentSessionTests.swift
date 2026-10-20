import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// #608 through a session: the capability, one framed delivery, a refusal with a reason, and the policy still applying.
@Suite struct PastedContentSessionTests {
    private func readySession(tier: Tier = .open) async throws -> (HostSession, FakeAdapter) {
        var policy = Policy()
        try policy.allow("tmux:a", binding: "binding-a", tier: tier)
        let (host, adapter) = try await sessionHost(targets: [AdapterTarget(name: "a", binding: "binding-a")],
                                                    policy: policy)
        let session = HostSession(host: host, authorizer: PersonalTerminalAuthorizer())
        let hello = await session.receive(helloFrame())
        guard case .hello(let info) = try onlyControl(hello) else { throw TestSupportError.expectedOneControl }
        #expect(info.capabilities.contains(PastedText.capability))
        _ = await session.receive(sessionFrame(payload: .control(.select(targetID: "tmux:a"))))
        return (session, adapter)
    }

    private func pasteFrame(_ spoken: String, _ pasted: String) -> Frame {
        sessionFrame(target: "tmux:a", payload: .text(TextPayload(text: spoken, pasted: PastedText(text: pasted))))
    }

    @Test func aPasteIsDeliveredAsOneFramedLineEvenPastTheSpokenCap() async throws {
        let (session, adapter) = try await readySession()
        let pasted = String(repeating: "A synthetic paragraph of notes.\n", count: 600) // about 19 KB
        let result = await GuardBudgetClock.$current.withValue(.frozen) {
            await session.receive(pasteFrame("compare this", pasted))
        }
        #expect(result.frames.isEmpty)
        let framed = try PastedContent.frame(spoken: "compare this", pasted: pasted)
        #expect(framed.utf8.count > 8_192)
        #expect(await adapter.deliveries.map(\.text) == [framed])
    }

    @Test func aRefusedPasteSaysWhyAndDeliversNothing() async throws {
        let (session, adapter) = try await readySession()
        let result = await session.receive(pasteFrame("compare this", "abc\u{202E}def"))
        guard case .error(let code, let message) = try onlyControl(result) else {
            Issue.record("expected a refusal")
            return
        }
        #expect(code == .malformed)
        #expect(message == "pasted text contains a bidirectional control; remove it and paste again")
        #expect(await adapter.deliveries.isEmpty)
    }

    /// A target whose adapter is not tmux takes a framed paste of at most 8 KB; a larger one is refused with the
    /// plain reason before any delivery.
    @Test func aNonTmuxTargetRefusesAPastePastItsCapWithAReason() async throws {
        let adapter = FakeAdapter(kind: "codex", targets: [AdapterTarget(name: "a", binding: "binding-a")])
        let registry = Registry()
        try await registry.register(adapter)
        var policy = Policy()
        try policy.allow("codex:a", binding: "binding-a", tier: .open)
        let host = try HailHost(registry: registry, store: InMemoryPolicyStore(policy))
        let session = HostSession(host: host, authorizer: PersonalTerminalAuthorizer())
        _ = await session.receive(helloFrame())
        _ = await session.receive(sessionFrame(payload: .control(.select(targetID: "codex:a"))))
        let note = String(repeating: "Synthetic line of notes.\n", count: 500) // about 12 KB
        let result = await session.receive(sessionFrame(
            target: "codex:a", payload: .text(TextPayload(text: "", pasted: PastedText(text: note)))
        ))
        guard case .error(let code, let message) = try onlyControl(result) else {
            Issue.record("expected a size refusal")
            return
        }
        #expect(code == .malformed)
        #expect(message.hasPrefix("pasted text is too large for this destination"))
        #expect(message.hasSuffix("the limit is \(PayloadLimits.maxTextBytes)"))
        #expect(await adapter.deliveries.isEmpty)
        let small = await GuardBudgetClock.$current.withValue(.frozen) {
            await session.receive(sessionFrame(
                target: "codex:a", payload: .text(TextPayload(text: "", pasted: PastedText(text: "short note")))
            ))
        }
        #expect(small.frames.isEmpty)
        #expect(await adapter.deliveries.count == 1)
    }

    private func expectGuarded(_ result: HostSessionResult, _ adapter: FakeAdapter) async throws {
        guard case .error(let code, let message) = try onlyControl(result) else {
            Issue.record("expected a confirmation refusal")
            return
        }
        #expect(code == .notAllowed)
        #expect(message == "target requires confirmation at the Mac")
        #expect(await adapter.deliveries.isEmpty)
    }

    /// Mick's decision: guarded words inside a paste are a validation flag, not a refusal. The paste is delivered,
    /// still framed as untrusted data, with the matched rules named outside its body.
    @Test func guardedWordsInsideAPasteAreFlaggedAndDelivered() async throws {
        let (session, adapter) = try await readySession()
        let pasted = "Synthetic: please delete the old branch\nthen sudo reboot"
        let result = await GuardBudgetClock.$current.withValue(.frozen) {
            await session.receive(pasteFrame("what does this mean", pasted))
        }
        #expect(result.frames.isEmpty)
        let framed = try PastedContent.frame(spoken: "what does this mean", pasted: pasted)
        let flagged = framed.replacingOccurrences(
            of: PastedContent.open,
            with: #"<pasted_content source="hail" trust="untrusted" encoding="json-string""#
                + #" validation="contains: sudo, delete">"#
        )
        #expect(await adapter.deliveries.map(\.text) == [flagged])
    }

    /// Regression: the same words typed or spoken without a paste are guarded exactly as before.
    @Test func theSameWordsSpokenAloneAreStillGuarded() async throws {
        let (session, adapter) = try await readySession()
        let result = await GuardBudgetClock.$current.withValue(.frozen) {
            await session.receive(sessionFrame(
                target: "tmux:a", payload: .text(TextPayload(text: "please delete the old branch"))
            ))
        }
        try await expectGuarded(result, adapter)
    }

    /// The spoken part of a request with a paste is still guarded, even when the paste itself is clean.
    @Test func aGuardedSpokenPartBesideACleanPasteIsStillGuarded() async throws {
        let (session, adapter) = try await readySession()
        let result = await GuardBudgetClock.$current.withValue(.frozen) {
            await session.receive(pasteFrame("delete everything this mentions", "Synthetic lunch notes."))
        }
        try await expectGuarded(result, adapter)
    }

    /// The #628 review's timeout finding: a budget that runs out on the paste body is not a hit, while on the spoken
    /// part it still fails closed.
    @Test func aGuardTimeoutOnThePasteIsNotAHitButOnTheSpokenPartItIs() async throws {
        let (session, adapter) = try await readySession()
        let clean = await GuardBudgetClock.$current.withValue(.expiring()) {
            await session.receive(pasteFrame("", "Synthetic lunch notes."))
        }
        #expect(clean.frames.isEmpty)
        #expect(await adapter.deliveries.count == 1)
        #expect(await adapter.deliveries.first?.text.contains("validation=") == false)
        let spoken = await GuardBudgetClock.$current.withValue(.expiring()) {
            await session.receive(pasteFrame("summarise this", "Synthetic lunch notes."))
        }
        guard case .error(let code, _) = try onlyControl(spoken) else {
            Issue.record("expected the spoken part's timeout to fail closed")
            return
        }
        #expect(code == .notAllowed)
        #expect(await adapter.deliveries.count == 1)
    }

    /// A large benign paste on the real clock, with no frozen budget: it is delivered, unflagged.
    @Test func aLargeBenignPasteIsDeliveredOnTheRealClock() async throws {
        let (session, adapter) = try await readySession()
        let pasted = String(repeating: "Synthetic notes about the weather and lunch plans.\n", count: 600) // ~31 KB
        let result = await session.receive(pasteFrame("summarise this", pasted))
        #expect(result.frames.isEmpty)
        #expect(await adapter.deliveries.count == 1)
    }

    @Test func spokenTextAloneKeepsTheSpokenCap() async throws {
        let (session, adapter) = try await readySession()
        let long = String(repeating: "word ", count: 500) // 2,500 characters: over the spoken 2,000
        let result = await session.receive(sessionFrame(target: "tmux:a", payload: .text(TextPayload(text: long))))
        guard case .error = try onlyControl(result) else {
            Issue.record("expected a refusal")
            return
        }
        #expect(await adapter.deliveries.isEmpty)
    }
}
