import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// #608 through a session: the capability, one framed delivery to an agent session only, a refusal with a reason, and
/// the policy still applying.
@Suite struct PastedContentSessionTests {
    private struct Ready {
        let session: HostSession
        let adapter: FakeAdapter
        let target: String
    }

    private func readySession(
        kind: String = "codex-owned", deviceCapabilities: [String] = [RequestRefusals.capability]
    ) async throws -> Ready {
        let adapter = FakeAdapter(kind: kind, targets: [AdapterTarget(name: "a", binding: "binding-a")])
        let registry = Registry()
        try await registry.register(adapter)
        let target = "\(kind):a"
        var policy = Policy()
        try policy.allow(target, binding: "binding-a", tier: .open)
        let host = try HailHost(registry: registry, store: InMemoryPolicyStore(policy))
        let session = HostSession(host: host, authorizer: PersonalTerminalAuthorizer())
        let hello = await session.receive(helloFrame(capabilities: deviceCapabilities))
        guard case .hello(let info) = try onlyControl(hello) else { throw TestSupportError.expectedOneControl }
        #expect(info.capabilities.contains(PastedText.capability))
        _ = await session.receive(sessionFrame(payload: .control(.select(targetID: target))))
        return Ready(session: session, adapter: adapter, target: target)
    }

    private func pasteFrame(_ spoken: String, _ pasted: String, to target: String) -> Frame {
        sessionFrame(target: target, payload: .text(TextPayload(text: spoken, pasted: PastedText(text: pasted))))
    }

    private func refusal(_ result: HostSessionResult) throws -> (ErrorCode, String)? {
        guard case .error(let code, let message, _) = try onlyControl(result) else { return nil }
        return (code, message)
    }

    @Test func aPasteIsDeliveredToAnAgentSessionAsOneFramedLinePastTheSpokenCap() async throws {
        let ready = try await readySession()
        let (session, adapter, target) = (ready.session, ready.adapter, ready.target)
        let pasted = String(repeating: "A synthetic paragraph of notes.\n", count: 200) // about 6 KB
        let result = await GuardBudgetClock.$current.withValue(.frozen) {
            await session.receive(pasteFrame("compare this", pasted, to: target))
        }
        #expect(result.frames.isEmpty)
        let framed = try PastedContent.frame(spoken: "compare this", pasted: pasted)
        #expect(framed.count > 2_000)
        let delivered = await adapter.deliveries.map { PastedContentTests.masked($0.text) }
        #expect(delivered == [PastedContentTests.masked(framed)])
    }

    /// Jarvis and the #628 review: a raw shell pane must never receive a paste. tmux panes, and any kind not known to
    /// be an agent session, are refused with a plain reason and nothing is delivered.
    @Test(arguments: ["tmux-reply", "diagnostic-reply", "unknown"])
    func aPasteToATargetNotKnownToBeAnAgentIsRefused(kind: String) async throws {
        let ready = try await readySession(kind: kind)
        let (session, adapter, target) = (ready.session, ready.adapter, ready.target)
        let result = await session.receive(pasteFrame("compare this", "notes", to: target))
        let refused = try #require(try refusal(result))
        #expect(refused.0 == .pasteRefused)
        #expect(refused.1 == "pastes go only to agent sessions")
        #expect(await adapter.deliveries.isEmpty)
        // Spoken text alone still goes to that target as before.
        let spoken = await GuardBudgetClock.$current.withValue(.frozen) {
            await session.receive(sessionFrame(target: target, payload: .text(TextPayload(text: "compare this"))))
        }
        #expect(spoken.frames.isEmpty)
        #expect(await adapter.deliveries.count == 1)
    }

    @Test func aPastePastTheAgentTargetsCapIsRefusedWithAReason() async throws {
        let ready = try await readySession()
        let (session, adapter, target) = (ready.session, ready.adapter, ready.target)
        let note = String(repeating: "Synthetic line of notes.\n", count: 500) // about 12 KB
        let refused = try #require(try refusal(await session.receive(pasteFrame("", note, to: target))))
        #expect(refused.0 == .pasteRefused)
        #expect(refused.1.hasPrefix("pasted text is too large for this destination"))
        // The cap shown keeps room for the validation note.
        #expect(refused.1.hasSuffix("the limit is \(PayloadLimits.maxTextBytes - PastedContent.validationReserve)"))
        #expect(await adapter.deliveries.isEmpty)
    }

    @Test func aRefusedPasteSaysWhyAndDeliversNothing() async throws {
        let ready = try await readySession()
        let (session, adapter, target) = (ready.session, ready.adapter, ready.target)
        let result = await session.receive(pasteFrame("compare", "abc\u{202E}def", to: target))
        let refused = try #require(try refusal(result))
        #expect(refused.0 == .pasteRefused)
        #expect(refused.1 == "pasted text contains a bidirectional control; remove it and paste again")
        #expect(await adapter.deliveries.isEmpty)
    }

    /// A device that did not advertise `request_refusals` is answered with the old codes, as before (#608).
    @Test func aDeviceWithoutRequestRefusalsGetsTheOldCodes() async throws {
        let ready = try await readySession(deviceCapabilities: ["probe"])
        let refused = try #require(try refusal(await ready.session.receive(
            pasteFrame("compare", "abc\u{202E}def", to: ready.target)
        )))
        #expect(refused.0 == .malformed)
        let guarded = try #require(try refusal(await GuardBudgetClock.$current.withValue(.frozen) {
            await ready.session.receive(pasteFrame("delete it", "notes", to: ready.target))
        }))
        #expect(guarded.0 == .notAllowed)
    }

    @Test func spokenTextAloneKeepsTheSpokenCap() async throws {
        let ready = try await readySession()
        let (session, adapter, target) = (ready.session, ready.adapter, ready.target)
        let long = String(repeating: "word ", count: 500) // 2,500 characters: over the spoken 2,000
        let result = await session.receive(sessionFrame(target: target, payload: .text(TextPayload(text: long))))
        #expect(try refusal(result) != nil)
        #expect(await adapter.deliveries.isEmpty)
    }
}
