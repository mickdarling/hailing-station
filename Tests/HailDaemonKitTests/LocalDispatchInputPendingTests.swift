import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

/// #894: unsent text already in the target's input is refused by name, from the tmux adapter through local dispatch
/// and the phone's text path, while policy, lockdown, rebind and every other refusal of the target keep the generic
/// `deliveryRefused`. Only the name changes: what is refused, and when, is as before. Scripted tmux runners and fake
/// adapters only; no tmux process is spawned.
@Suite struct LocalDispatchInputPendingTests {
    private static let target = "tmux:codex"
    private static let binding = "$2@1758230001/%2:502"
    private static let listed = AdapterTarget(name: "codex", binding: binding)

    /// A negotiated session selecting `target`, on a host whose policy allows it at `tier`.
    private static func session(_ adapter: any Adapter, tier: Tier = .open) async throws -> (HostSession, HailHost) {
        let registry = Registry()
        try await registry.register(adapter)
        var policy = Policy(guardPatterns: [.init(name: "synthetic guard", regex: "^synthetic guarded command$")],
                            deliveriesPerMinute: 1_000)
        try policy.allow(target, binding: binding, tier: tier)
        let host = try HailHost(registry: registry, store: InMemoryPolicyStore(policy))
        let session = HostSession(host: host, authorizer: PersonalTerminalAuthorizer(), hostName: "mac-test")
        _ = await session.receive(helloFrame())
        _ = await session.receive(sessionFrame(payload: .control(.select(targetID: target))))
        return (session, host)
    }

    private static func request(_ text: String) -> LocalDispatchRequest {
        LocalDispatchRequest(connection: UUID(), target: target, binding: binding, text: text)
    }

    private static func tmux(_ runner: FakeCommandRunner) -> TmuxAdapter {
        TmuxAdapter(runner: runner, pollInterval: nil, submitTiming: EvidenceHarness.timing())
    }

    /// The pane draws `typed` at the cursor once the paste buffer starts to fill: text appearing mid-delivery.
    private static func appearingRunner(_ typed: String) -> FakeCommandRunner {
        let screen = Mutex("> \n2,0,80\n")
        return FakeCommandRunner { arguments in
            if arguments.contains("list-sessions") { return CommandResult(exitCode: 0, stdout: twoSessions) }
            if arguments.contains("set-buffer") { screen.withLock { $0 = "> \(typed)\n\(typed.count + 2),0,80\n" } }
            if arguments.contains("capture-pane") { return CommandResult(exitCode: 0, stdout: screen.withLock { $0 }) }
            return CommandResult(exitCode: 0, stdout: "")
        }
    }

    // MARK: The adapter names each reason

    @Test func eachTmuxPendingInputRefusalIsNamedWithTheReasonItsEvidenceGives() async throws {
        let stale = EvidenceHarness(ScriptedPane(baseline: ScriptedPane.typedScreen, stale: .max), timing: .fast)
        await #expect(throws: AdapterError.inputPending(reason: .staleInput)) {
            try await stale.adapter.deliver("synthetic input", to: "codex", binding: nil)
        }

        let appeared = EvidenceHarness(Self.appearingRunner("ZULIP"), timing: .fast)
        await #expect(throws: AdapterError.inputPending(reason: .appeared)) {
            try await appeared.adapter.deliver("ZULIP", to: "codex", binding: nil)
        }
        #expect(!(await appeared.runner.calls).contains { $0.contains("paste-buffer") }, "refused before the paste")

        let taintedPane = ScriptedPane()
        // tmux refuses the Enter: a submit decided failed by the script alone, never by a lapsed confirm deadline.
        let tainted = EvidenceHarness(taintedPane.refusingEnter(), timing: .fast)
        // A submit that never succeeded is a delivery failure, not pending input; it taints the pane.
        await #expect(throws: AdapterError.deliveryFailed("synthetic refusal")) {
            try await tainted.adapter.deliver("synthetic input", to: "codex", binding: nil)
        }
        taintedPane.reset(baseline: ScriptedPane.oldScreen)
        await #expect(throws: AdapterError.inputPending(reason: .tainted)) {
            try await tainted.adapter.deliver("later input", to: "codex", binding: nil)
        }

        // The appeared case also pins the paste step's refusal text that `performDelivery` names: were it reworded,
        // this would be a generic `deliveryFailed`. The error's reason is the evidence line's token (#894 PR 1).
        for (harness, reason) in [(stale, PendingInputReason.staleInput), (appeared, .appeared), (tainted, .tainted)] {
            let line = try #require(harness.evidence.lines("tmux_input_pending").only)
            #expect(line.hasPrefix("tmux_input_pending reason=\(reason.rawValue) "))
        }
        #expect("\(AdapterError.inputPending(reason: .staleInput))" == "inputPending(reason: stale_input)")
    }

    // MARK: Through local dispatch

    @Test func textAlreadyInTheInputIsRefusedAsInputPending() async throws {
        let pane = ScriptedPane(baseline: ScriptedPane.typedScreen, stale: .max)
        let scripted = FakeCommandRunner { pane.respond($0) }
        let (session, _) = try await Self.session(Self.tmux(scripted))
        await #expect(throws: LocalDispatchRefusal.inputPending) {
            try await session.dispatch(Self.request("synthetic input"))
        }
        #expect(await pastedTexts(on: scripted).isEmpty, "refused before any paste, as before")
        #expect(await session.replyRequests.isEmpty)
    }

    @Test func textThatAppearsWhileTheBufferFillsIsRefusedAsInputPending() async throws {
        let runner = Self.appearingRunner("ZULIP")
        let (session, _) = try await Self.session(Self.tmux(runner))
        await #expect(throws: LocalDispatchRefusal.inputPending) { try await session.dispatch(Self.request("ZULIP")) }
        #expect(!(await runner.calls).contains { $0.contains("paste-buffer") }, "refused before the paste, as before")
    }

    @Test func aTaintedPaneIsRefusedAsInputPendingAndItsFailedSubmitIsNot() async throws {
        let pane = ScriptedPane()
        // tmux refuses the Enter after the paste, so the submit fails by the script, never by a lapsed deadline.
        let runner = pane.refusingEnter()
        let (session, _) = try await Self.session(Self.tmux(runner))
        // The text is pasted and never known submitted: an ordinary delivery failure, still the generic refusal.
        await #expect(throws: LocalDispatchRefusal.deliveryRefused) {
            try await session.dispatch(Self.request("synthetic input"))
        }
        // The owner clears the input by hand; the taint still refuses, now by name, and nothing more is typed.
        pane.reset(baseline: ScriptedPane.oldScreen)
        await #expect(throws: LocalDispatchRefusal.inputPending) {
            try await session.dispatch(Self.request("later input"))
        }
        #expect(await runner.delivered == ["synthetic input", "Enter"])
    }

    @Test func everyOtherRefusalOfTheTargetStaysDeliveryRefused() async throws {
        // Policy: allowed at the locked tier, so selectable and never delivered to.
        let (locked, _) = try await Self.session(FakeAdapter(kind: "tmux", targets: [Self.listed]), tier: .locked)
        // Lockdown, engaged after the selection.
        let (lockedDown, host) = try await Self.session(FakeAdapter(kind: "tmux", targets: [Self.listed]))
        _ = await host.engageLockdown(reason: "synthetic lockdown")
        // A rebind the adapter sees at delivery, and an ordinary adapter failure.
        let (rebound, _) = try await Self.session(
            FakeAdapter(kind: "tmux", targets: [Self.listed], deliverError: AdapterError.rebound("codex"))
        )
        let (failed, _) = try await Self.session(
            FakeAdapter(kind: "tmux", targets: [Self.listed], deliverError: AdapterError.deliveryFailed("synthetic"))
        )
        for session in [locked, lockedDown, rebound, failed] {
            await #expect(throws: LocalDispatchRefusal.deliveryRefused) {
                try await session.dispatch(Self.request("synthetic input"))
            }
        }
        // Pending input from any adapter, whatever its reason, is the named one.
        for reason in [PendingInputReason.staleInput, .appeared, .tainted] {
            let (session, _) = try await Self.session(FakeAdapter(
                kind: "tmux", targets: [Self.listed], deliverError: AdapterError.inputPending(reason: reason)
            ))
            await #expect(throws: LocalDispatchRefusal.inputPending) {
                try await session.dispatch(Self.request("synthetic input"))
            }
        }
    }

    @Test func theNamedRefusalKeepsTheGenericRefusalsCodeAndSaysWhatHappened() {
        let named = LocalDispatchRefusal.inputPending
        #expect(named.message == "dispatch refused [inputPending]: the target's input already holds unsent text")
        #expect(named.code == LocalDispatchRefusal.deliveryRefused.code)
        #expect(!named.handedOff)
        #expect(LocalDispatchRefusal.deliveryRefused.message
            == "dispatch refused [deliveryRefused]: target action was refused")
    }

    // MARK: Through the phone's text path

    @Test func thePhoneIsToldPlainlyOnTheSameCodeAndOtherRefusalsAreUnchanged() async throws {
        let text = sessionFrame(target: Self.target, payload: .text(TextPayload(text: "synthetic input")))
        let (pending, _) = try await Self.session(FakeAdapter(
            kind: "tmux", targets: [Self.listed], deliverError: AdapterError.inputPending(reason: .staleInput)
        ))
        #expect(try onlyControl(await pending.receive(text)) == .error(
            code: .notAllowed, message: "the target's input already holds unsent text"
        ))
        let (rebound, _) = try await Self.session(
            FakeAdapter(kind: "tmux", targets: [Self.listed], deliverError: AdapterError.rebound("codex"))
        )
        #expect(try onlyControl(await rebound.receive(text)) == .error(
            code: .notAllowed, message: "target action was refused"
        ))
    }
}

private extension TmuxSubmitTiming {
    /// Fast waits; a clear limit short enough that pending text is refused quickly.
    static var fast: Self { EvidenceHarness.timing() }
}
