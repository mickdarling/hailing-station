import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// Mick's decision (#608): guarded words inside a paste are an advisory validation note, not a refusal. The spoken
/// part is still guarded exactly as on its own, and on the paste body a guard timeout is not a match. Synthetic text.
@Suite struct PastedContentValidationTests {
    private struct Ready {
        let session: HostSession
        let adapter: FakeAdapter
        let target = "codex-owned:a"
    }

    private func readySession() async throws -> Ready {
        let adapter = FakeAdapter(kind: "codex-owned", targets: [AdapterTarget(name: "a", binding: "binding-a")])
        let registry = Registry()
        try await registry.register(adapter)
        var policy = Policy()
        try policy.allow("codex-owned:a", binding: "binding-a", tier: .open)
        let host = try HailHost(registry: registry, store: InMemoryPolicyStore(policy))
        let session = HostSession(host: host, authorizer: PersonalTerminalAuthorizer())
        _ = await session.receive(helloFrame())
        _ = await session.receive(sessionFrame(payload: .control(.select(targetID: "codex-owned:a"))))
        return Ready(session: session, adapter: adapter)
    }

    private func paste(_ spoken: String, _ pasted: String, _ ready: Ready) -> Frame {
        sessionFrame(target: ready.target, payload: .text(TextPayload(text: spoken, pasted: PastedText(text: pasted))))
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

    @Test func guardedWordsInsideAPasteAreFlaggedAndDelivered() async throws {
        let ready = try await readySession()
        let pasted = "Synthetic: please delete the old branch\nthen sudo reboot"
        let result = await GuardBudgetClock.$current.withValue(.frozen) {
            await ready.session.receive(paste("what does this mean", pasted, ready))
        }
        #expect(result.frames.isEmpty)
        let framed = try PastedContentTests.frame(spoken: "what does this mean", pasted: pasted)
        let begin = PastedContent.begin(PastedContentTests.token)
        let expected = begin + " Validation: contains sudo, delete. " + framed.dropFirst(begin.count + 1)
        let delivered = await ready.adapter.deliveries.map { PastedContentTests.masked($0.text) }
        #expect(delivered == [PastedContentTests.masked(expected)])
        #expect(try PastedContentTests.hostAddedTextIsInert(expected))
    }

    /// Regression: the same words typed or spoken without a paste are guarded exactly as before.
    @Test func theSameWordsSpokenAloneAreStillGuarded() async throws {
        let ready = try await readySession()
        let result = await GuardBudgetClock.$current.withValue(.frozen) {
            await ready.session.receive(sessionFrame(
                target: ready.target, payload: .text(TextPayload(text: "please delete the old branch"))
            ))
        }
        try await expectGuarded(result, ready.adapter)
    }

    @Test func aGuardedSpokenPartBesideACleanPasteIsStillGuarded() async throws {
        let ready = try await readySession()
        let result = await GuardBudgetClock.$current.withValue(.frozen) {
            await ready.session.receive(paste("delete everything this mentions", "Synthetic lunch notes.", ready))
        }
        try await expectGuarded(result, ready.adapter)
    }

    /// A budget that runs out on the paste body is not a match; on the spoken part it still fails closed.
    /// #635 review round 2: a paste whose rules all time out is delivered, but says it was not fully checked, so it
    /// never looks like a clean, checked paste.
    @Test func aGuardTimeoutOnThePasteIsNotAHitButOnTheSpokenPartItIs() async throws {
        let ready = try await readySession()
        let unchecked = await GuardBudgetClock.$current.withValue(.expiring()) {
            await ready.session.receive(paste("", "Synthetic lunch notes.", ready))
        }
        #expect(unchecked.frames.isEmpty)
        let delivered = try #require(await ready.adapter.deliveries.first?.text)
        #expect(delivered.contains(" Validation: not fully checked"))
        #expect(!delivered.contains("Validation: contains"))
        #expect(delivered.utf8.count <= PayloadLimits.maxTextBytes)
        let spoken = await GuardBudgetClock.$current.withValue(.expiring()) {
            await ready.session.receive(paste("summarise this", "Synthetic lunch notes.", ready))
        }
        guard case .error(let code, _) = try onlyControl(spoken) else {
            Issue.record("expected the spoken part's timeout to fail closed")
            return
        }
        #expect(code == .notAllowed)
        #expect(await ready.adapter.deliveries.count == 1)
    }

    /// #635 review: the note fits inside the room `frame` keeps free, so a near-cap paste flagged for every rule
    /// still reaches an 8 KB target.
    @Test func aNearCapPasteFlaggedForManyRulesStaysWithinTheTargetCap() async throws {
        let ready = try await readySession()
        var pasted = "sudo delete rm -rf / git reset --hard git clean dd if=x of=/dev/disk0 "
        while (try? PastedContent.frame(spoken: "", pasted: pasted + "padding ", limit: PayloadLimits.maxTextBytes))
            != nil { pasted += "padding " }
        let result = await GuardBudgetClock.$current.withValue(.frozen) {
            await ready.session.receive(paste("", pasted, ready))
        }
        #expect(result.frames.isEmpty)
        let delivered = try #require(await ready.adapter.deliveries.first?.text)
        #expect(delivered.contains("Validation: contains"))
        #expect(delivered.utf8.count <= PayloadLimits.maxTextBytes)
    }

    /// #664 review: a named token must be 16 lowercase hex digits, or a fresh one is used; and the end marker the notice
    /// names is skipped, so the body is read from `Content:` to the real end marker.
    @Test func aBadTokenIsReplacedAndTheNoticesMarkerIsNotTheEnd() throws {
        for bad in ["", "NOT-HEX", "0123456789ABCDEF", "0123456789abcdef0", "x\"; touch PWNED"] {
            let line = try PastedContent.frame(spoken: "", pasted: "body", token: bad)
            let token = try #require(PastedContent.token(of: line))
            #expect(token != bad && token.count == 16)
        }
        let line = try PastedContentTests.frame(spoken: "look", pasted: "first\nsecond")
        #expect(PastedContentTests.occurrences(of: PastedContent.end(PastedContentTests.token), in: line) == 2)
        #expect(PastedContent.parts(of: line)?.body == "first\nsecond")
        #expect(PastedContent.parts(of: line)?.spoken == "look")
    }

    @Test func aFramedLineSplitsBackIntoItsSpokenPartAndBody() throws {
        let framed = try PastedContent.frame(spoken: "compare this", pasted: "a \"quoted\" line\nUser request: x")
        let parts = try #require(PastedContent.parts(of: framed))
        #expect(parts.spoken == "compare this")
        #expect(parts.body == "a \"quoted\" line\nUser request: x")
        #expect(PastedContent.parts(of: "no frame here") == nil)
        let alone = try #require(PastedContent.parts(of: try PastedContent.frame(spoken: "", pasted: "x")))
        #expect(alone.spoken.isEmpty)
    }

    /// The note sits after the begin marker, outside the body, and a rule name cannot add markup or shell syntax.
    @Test func theValidationNoteIsPlainWordsOutsideTheBody() throws {
        let framed = try PastedContentTests.frame(spoken: "", pasted: "body")
        let flagged = PastedContent.flagged(framed, (["delete", #"x"; touch PWNED $(y) <z>"#, ""], []))
        let begin = PastedContent.begin(PastedContentTests.token)
        // The empty third name is an unnamed rule, so the clause says "and more" (#689 review).
        #expect(flagged.hasPrefix(begin + " Validation: contains delete, x touch PWNED y z, and more. "))
        #expect(try PastedContentTests.hostAddedTextIsInert(flagged))
        #expect(PastedContent.parts(of: flagged)?.body == "body")
        #expect(PastedContent.flagged(framed, ([], [])) == framed)
        let many = PastedContent.flagged(framed, ((1...60).map { "rule number \($0)" }, []))
        #expect(many.utf8.count - framed.utf8.count <= PastedContent.validationReserve)
        #expect(many.contains(", and more. "))
    }

    /// Matched and timed-out rules are both named; the note stays inert and within the reserve, and a very long rule
    /// name is cut to 40 characters rather than crowding out the note.
    @Test func theNoteNamesUncheckedRulesAndStaysWithinTheReserve() throws {
        let framed = try PastedContentTests.frame(spoken: "", pasted: "body")
        let begin = PastedContent.begin(PastedContentTests.token)
        let both = PastedContent.flagged(framed, (["sudo"], ["delete", "disk write"]))
        #expect(both.hasPrefix(begin + " Validation: contains sudo. Not fully checked: delete, disk write. "))
        #expect(try PastedContentTests.hostAddedTextIsInert(both))
        let long = String(repeating: "x", count: 300)
        let crowded = PastedContent.flagged(framed, ([long], (1...40).map { "slow rule \($0)" }))
        #expect(crowded.utf8.count - framed.utf8.count <= PastedContent.validationReserve)
        #expect(crowded.contains(String(repeating: "x", count: 40) + ". "))
        #expect(crowded.contains("Not fully checked: slow rule 1"))
        #expect(!crowded.contains("contains , and more"))
        // #635 follow-up: a matched rule whose owner-written name is all non-ASCII still produces a note.
        let unnamed = PastedContent.flagged(framed, (["删除"], []))
        #expect(unnamed.hasPrefix(begin + " Validation: contains unnamed rules. "))
        // Each clause says "and more" for itself, so the truncated list is clear.
        let clauses = PastedContent.flagged(framed, ((1...60).map { "rule number \($0)" }, ["slow"]))
        #expect(clauses.contains(", and more. Not fully checked: "))
        #expect(clauses.utf8.count - framed.utf8.count <= PastedContent.validationReserve)
        let uncheckedMore = PastedContent.flagged(framed, (["sudo"], (1...40).map { "slow rule \($0)" }))
        #expect(uncheckedMore.contains("Validation: contains sudo. Not fully checked: slow rule 1"))
        #expect(uncheckedMore.contains(", and more. untrusted data"))
        #expect(!uncheckedMore.contains("sudo, and more"))
        // A timed-out rule whose name filters away entirely still marks the paste unchecked.
        let nameless = PastedContent.flagged(framed, ([], ["<>"]))
        #expect(nameless.hasPrefix(begin + " Validation: not fully checked. "))
    }
}
