import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// #665 review: on a request that carries a paste, only `not_allowed` and `malformed` refusals become `paste_refused`.
/// Lockdown and unknown targets keep their own codes, so a device in lockdown still hears lockdown, as for speech.
@Suite struct PasteRefusalCodeTests {
    private struct Ready {
        let session: HostSession
        let host: HailHost
        let adapter: FakeAdapter
    }

    private func ready() async throws -> Ready {
        let adapter = FakeAdapter(kind: "codex-owned", targets: [AdapterTarget(name: "a", binding: "binding-a")])
        let registry = Registry()
        try await registry.register(adapter)
        var policy = Policy()
        try policy.allow("codex-owned:a", binding: "binding-a", tier: .open)
        let host = try HailHost(registry: registry, store: InMemoryPolicyStore(policy))
        let session = HostSession(host: host, authorizer: PersonalTerminalAuthorizer())
        _ = await session.receive(helloFrame(capabilities: [RequestRefusals.capability]))
        _ = await session.receive(sessionFrame(payload: .control(.select(targetID: "codex-owned:a"))))
        return Ready(session: session, host: host, adapter: adapter)
    }

    private func code(_ result: HostSessionResult) throws -> ErrorCode? {
        guard case .error(let code, _, _) = try onlyControl(result) else { return nil }
        return code
    }

    private func paste(_ spoken: String = "look", _ pasted: String = "notes") -> Frame {
        let payload = TextPayload(text: spoken, pasted: PastedText(text: pasted))
        return sessionFrame(target: "codex-owned:a", payload: .text(payload))
    }

    @Test func notAllowedBecomesAPasteRefusal() async throws {
        let ready = try await ready()
        let result = await GuardBudgetClock.$current.withValue(.frozen) {
            await ready.session.receive(paste("delete it"))
        }
        #expect(try code(result) == .pasteRefused)
    }

    @Test func malformedBecomesAPasteRefusal() async throws {
        let ready = try await ready()
        #expect(try code(await ready.session.receive(paste("look", "a\u{202E}b"))) == .pasteRefused)
    }

    @Test func lockdownStaysLockdown() async throws {
        let ready = try await ready()
        _ = await ready.host.engageLockdown(reason: "synthetic test")
        #expect(try code(await ready.session.receive(paste())) == .lockdown)
        #expect(await ready.adapter.deliveries.isEmpty)
    }

    /// #665 review: lockdown is checked before framing, so even a paste that framing would refuse hears lockdown.
    @Test func lockdownComesBeforeThePastesOwnRefusals() async throws {
        let ready = try await ready()
        _ = await ready.host.engageLockdown(reason: "synthetic test")
        #expect(try code(await ready.session.receive(paste("look", "a\u{202E}b"))) == .lockdown)
    }

    /// #665 review: a rate limit (a full request table, `capacityExceeded`) keeps its code on a paste request.
    @Test func everyCodeButNotAllowedAndMalformedPassesThrough() {
        let collapsed: Set<String> = ["not_allowed", "malformed"]
        for code in [ErrorCode.notAllowed, .malformed, .rateLimited, .lockdown, .unknownTarget, .unauthorized,
                     .protocolVersion] {
            let answered = HostSession.refusalCode(code, carriesPaste: true, takesRequestRefusals: true)
            #expect(answered == (collapsed.contains(code.rawValue) ? .pasteRefused : code))
            #expect(HostSession.refusalCode(code, carriesPaste: false, takesRequestRefusals: true) == code)
            #expect(HostSession.refusalCode(code, carriesPaste: true, takesRequestRefusals: false) == code)
        }
    }

    @Test func anUnknownTargetStaysUnknownTarget() async throws {
        let ready = try await ready()
        await ready.adapter.setTargets([])
        #expect(try code(await ready.session.receive(paste())) == .unknownTarget)
    }
}
