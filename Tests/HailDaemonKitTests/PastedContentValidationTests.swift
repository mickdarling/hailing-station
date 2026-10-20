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
    @Test func aGuardTimeoutOnThePasteIsNotAHitButOnTheSpokenPartItIs() async throws {
        let ready = try await readySession()
        let clean = await GuardBudgetClock.$current.withValue(.expiring()) {
            await ready.session.receive(paste("", "Synthetic lunch notes.", ready))
        }
        #expect(clean.frames.isEmpty)
        #expect(await ready.adapter.deliveries.first?.text.contains("Validation:") == false)
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
        let flagged = PastedContent.flagged(framed, ["delete", #"x"; touch PWNED $(y) <z>"#, ""])
        let begin = PastedContent.begin(PastedContentTests.token)
        #expect(flagged.hasPrefix(begin + " Validation: contains delete, x touch PWNED y z. "))
        #expect(try PastedContentTests.hostAddedTextIsInert(flagged))
        #expect(PastedContent.parts(of: flagged)?.body == "body")
        #expect(PastedContent.flagged(framed, []) == framed)
        let many = PastedContent.flagged(framed, (1...60).map { "rule number \($0)" })
        #expect(many.utf8.count - framed.utf8.count <= PastedContent.validationReserve)
        #expect(many.contains(", and more. "))
    }
}
