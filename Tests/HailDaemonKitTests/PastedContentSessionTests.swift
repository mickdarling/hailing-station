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

    /// The dangerous-pattern guard reads the paste too: a guarded word inside it still needs a confirmation.
    @Test func aGuardedWordInsideAPasteStillNeedsConfirmation() async throws {
        let (session, adapter) = try await readySession()
        let result = await GuardBudgetClock.$current.withValue(.frozen) {
            await session.receive(pasteFrame("what does this mean", "Synthetic: please delete the old branch"))
        }
        guard case .error(let code, _) = try onlyControl(result) else {
            Issue.record("expected a confirmation refusal")
            return
        }
        #expect(code == .notAllowed)
        #expect(await adapter.deliveries.isEmpty)
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
