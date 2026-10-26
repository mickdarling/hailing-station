import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// #894 review round 1: naming the input-pending refusal changed nothing else. A paste from a device that takes
/// request refusals still hears `paste_refused`, the phone's connection stays open, and a cancelled local dispatch
/// caller still sees its own cancellation rather than the named refusal. Fake adapters only.
@Suite(.frozenGuardBudget) struct InputPendingUnchangedTests {
    private static let target = "tmux:codex"
    private static let binding = "$2@1758230001/%2:502"
    private static let reason = "the target's input already holds unsent text"

    /// A negotiated session, advertising `capabilities`, selecting `target` on an open-tier host.
    private static func session(
        _ adapter: any Adapter, capabilities: [String] = ["probe"]
    ) async throws -> HostSession {
        let registry = Registry()
        try await registry.register(adapter)
        var policy = Policy(guardPatterns: [.init(name: "synthetic guard", regex: "^synthetic guarded command$")],
                            deliveriesPerMinute: 1_000)
        try policy.allow(target, binding: binding, tier: .open)
        let host = try HailHost(registry: registry, store: InMemoryPolicyStore(policy))
        let session = HostSession(host: host, authorizer: PersonalTerminalAuthorizer(), hostName: "mac-test")
        _ = await session.receive(helloFrame(capabilities: capabilities))
        _ = await session.receive(sessionFrame(payload: .control(.select(targetID: target))))
        return session
    }

    private static func pending() -> FakeAdapter {
        FakeAdapter(kind: "tmux", targets: [AdapterTarget(name: "codex", binding: binding)],
                    deliverError: AdapterError.inputPending(reason: .staleInput))
    }

    /// The session still answers: a ping after the refusal gets its pong.
    private static func expectStillAnswering(_ session: HostSession) async throws {
        let ping = await session.receive(sessionFrame(payload: .control(.ping(nonce: "after-refusal"))))
        #expect(try onlyControl(ping) == .pong(nonce: "after-refusal"))
    }

    @Test func aPasteFromADeviceThatTakesRequestRefusalsStillHearsPasteRefused() async throws {
        let session = try await Self.session(Self.pending(), capabilities: [RequestRefusals.capability])
        let paste = sessionFrame(target: Self.target, payload: .text(
            TextPayload(text: "compare this", pasted: PastedText(text: "synthetic notes"))
        ))
        let result = await GuardBudgetClock.$current.withValue(.frozen) { await session.receive(paste) }
        #expect(try onlyControl(result) == .error(code: .pasteRefused, message: Self.reason))
        #expect(result.disposition == .keepOpen)
        try await Self.expectStillAnswering(session)
    }

    @Test func spokenTextKeepsNotAllowedAndTheConnectionStaysOpen() async throws {
        let session = try await Self.session(Self.pending(), capabilities: [RequestRefusals.capability])
        let text = sessionFrame(target: Self.target, payload: .text(TextPayload(text: "synthetic input")))
        let result = await session.receive(text)
        #expect(try onlyControl(result) == .error(code: .notAllowed, message: Self.reason))
        #expect(result.disposition == .keepOpen)
        try await Self.expectStillAnswering(session)
    }

    @Test func aCancelledDispatchCallerSeesCancellationNotTheNamedRefusal() async throws {
        let adapter = GatedPendingAdapter(binding: Self.binding)
        let session = try await Self.session(adapter)
        let request = LocalDispatchRequest(
            connection: UUID(), target: Self.target, binding: Self.binding, text: "synthetic input"
        )
        let dispatch = Task { try await session.dispatch(request) }
        // Cancelled while the adapter holds the delivery; the adapter then refuses with pending input.
        await adapter.waitForDelivery()
        dispatch.cancel()
        await adapter.releaseDelivery()
        await #expect(throws: CancellationError.self) { try await dispatch.value }
    }
}

/// Holds each delivery until released, then refuses it as pending input.
private actor GatedPendingAdapter: Adapter {
    nonisolated let kind = "tmux"
    private let binding: String
    private var entered = false
    private var arrival: CheckedContinuation<Void, Never>?
    private var release: CheckedContinuation<Void, Never>?

    init(binding: String) { self.binding = binding }

    func listTargets() async throws -> [AdapterTarget] { [AdapterTarget(name: "codex", binding: binding)] }
    func capture(_ target: String) async throws -> String { "" }
    func deliver(_ text: String, to target: String, binding: String?) async throws {
        entered = true
        arrival?.resume()
        arrival = nil
        await withCheckedContinuation { release = $0 }
        throw AdapterError.inputPending(reason: .staleInput)
    }

    func waitForDelivery() async {
        if entered { return }
        await withCheckedContinuation { arrival = $0 }
    }

    func releaseDelivery() {
        release?.resume()
        release = nil
    }
}
