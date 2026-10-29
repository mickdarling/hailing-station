import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1))) struct TmuxDeliveryAuthorityTests {
    @Test func retirementDuringBufferFillPastesNothing() async throws {
        let rig = try await TmuxAuthorityRig.make(.fill)
        defer { rig.runner.gate.fire() }
        let sending = Task { try await rig.send() }
        try await rig.runner.gate.waitUntilSuspended()
        try await rig.retire()
        await #expect(throws: HostError.denied(.notAllowed(TmuxAuthorityRig.target))) {
            try await rig.runner.gate.finish(sending)
        }
        #expect(rig.runner.pasted.isEmpty)
        #expect(rig.runner.enters == 0)
        #expect(rig.runner.calls.filter { $0.contains("set-buffer") }.count == 1)
        #expect(rig.runner.calls.last?.contains("delete-buffer") == true)
    }

    @Test func retirementAfterPasteLeavesUnsentInputTaintedAndRefusesEnter() async throws {
        let rig = try await TmuxAuthorityRig.make(.paste, input: "owner draft ")
        defer { rig.runner.gate.fire() }
        let sending = Task { try await rig.send() }
        try await rig.runner.gate.waitUntilSuspended()
        try await rig.retire()
        await #expect(throws: HostError.denied(.notAllowed(TmuxAuthorityRig.target))) {
            try await rig.runner.gate.finish(sending)
        }
        #expect(rig.runner.pasted == ["synthetic input"])
        #expect(rig.runner.enters == 0)
        #expect(rig.runner.input == "owner draft synthetic input")
        #expect(!rig.runner.calls.contains { $0.contains("send-keys") })
        #expect(rig.log.all.filter { $0.event == "tmux_policy_retired_unsent" } == [
            TmuxDeliveryEvidence(event: "tmux_policy_retired_unsent", detail: "")
        ])
        await #expect(throws: AdapterError.inputPending(reason: .tainted)) {
            let adapter: any Adapter = rig.adapter
            try await adapter.deliver(
                "later input", to: "codex", binding: TmuxAuthorityRig.binding,
                authority: rig.host.targetPolicy.snapshot(for: TmuxAuthorityRig.target).deliveryAuthority
            )
        }
        #expect(rig.runner.pasted == ["synthetic input"])
        #expect(!rig.runner.calls.contains { $0.joined(separator: " ").contains("send-keys") })
        #expect(rig.log.all.last?.detail.contains("reason=tainted") == true)
    }

    @Test(arguments: [false, true])
    func retirementDuringDefinitiveEnterRefusalTracksPriorEnter(retry: Bool) async throws {
        let rig = try await TmuxAuthorityRig.make(.enterRefusal)
        if retry { rig.runner.requireRetry() }
        defer { rig.runner.gate.fire() }
        let text = try PastedContent.frame(spoken: "synthetic input", pasted: "synthetic data")
        let sending = Task {
            let adapter: any Adapter = rig.adapter
            try await adapter.deliver(text, to: "codex", binding: TmuxAuthorityRig.binding, authority: rig.authority)
        }
        try await rig.runner.gate.waitUntilSuspended()
        try await rig.retire()
        await #expect(throws: HostError.denied(.notAllowed(TmuxAuthorityRig.target))) {
            try await rig.runner.gate.finish(sending)
        }
        #expect(rig.runner.pasted == [text])
        #expect(rig.runner.input == text + (retry ? "\n  " : ""))
        #expect(rig.runner.enters == (retry ? 1 : 0))
        await #expect(throws: AdapterError.inputPending(reason: .tainted)) {
            let adapter: any Adapter = rig.adapter
            try await adapter.deliver(
                "later input", to: "codex", binding: TmuxAuthorityRig.binding,
                authority: rig.host.targetPolicy.snapshot(for: TmuxAuthorityRig.target).deliveryAuthority
            )
        }
        #expect(rig.runner.pasted == [text])
        #expect(rig.runner.enters == (retry ? 1 : 0))
        #expect(rig.log.all.filter { $0.event == "tmux_policy_retired_unsent" } == (retry ? [] : [
            TmuxDeliveryEvidence(event: "tmux_policy_retired_unsent", detail: "")
        ]))
    }

    @Test func retirementAfterPasteNeverClearsAReboundPane() async throws {
        let rig = try await TmuxAuthorityRig.make(.paste)
        defer { rig.runner.gate.fire() }
        let sending = Task { try await rig.send() }
        try await rig.runner.gate.waitUntilSuspended()
        try await rig.retire()
        rig.runner.rebind()
        await #expect(throws: HostError.denied(.notAllowed(TmuxAuthorityRig.target))) {
            try await rig.runner.gate.finish(sending)
        }
        #expect(rig.runner.enters == 0)
        #expect(!rig.runner.calls.contains { $0.contains("send-keys") })
    }

    @Test func retirementWhileQueuedBehindAnotherPanePastesNothing() async throws {
        let rig = try await TmuxAuthorityRig.make(.paste)
        defer { rig.runner.gate.fire() }
        let first = Task { try await rig.adapter.deliver("first", to: "claude-hail", binding: nil) }
        try await rig.runner.gate.waitUntilSuspended()
        let checked = Mutex(false)
        let authority = DeliveryAuthority {
            checked.withLock { $0 = true }
            try rig.authority.requireCurrent()
        }
        let second = Task {
            let adapter: any Adapter = rig.adapter
            try await adapter.deliver("synthetic input", to: "codex", binding: TmuxAuthorityRig.binding,
                                      authority: authority)
        }
        try await selectionPreflightStep("queued delivery admission") {
            while !checked.withLock({ $0 }) { try Task.checkCancellation(); await Task.yield() }
        }
        try await rig.retire()
        try await rig.runner.gate.finish(first)
        await #expect(throws: HostError.denied(.notAllowed(TmuxAuthorityRig.target))) {
            try await selectionPreflightStep("queued delivery refusal") { try await second.value }
        }
        #expect(rig.runner.pasted == ["first"])
        #expect(rig.runner.enters == 1)
    }

    @Test func currentAuthorityKeepsTheMainPasteAndEnterSequence() async throws {
        let rig = try await TmuxAuthorityRig.make()
        try await rig.send()
        #expect(rig.runner.pasted == ["synthetic input"])
        #expect(rig.runner.enters == 1)
        let guarded = rig.runner.calls
        let plain = try await TmuxAuthorityRig.make()
        try await plain.adapter.deliver("synthetic input", to: "codex", binding: TmuxAuthorityRig.binding)
        // UUID buffer names vary; every command and its other arguments must remain the same.
        func normalized(_ calls: [[String]]) -> [[String]] {
            calls.map { $0.map { $0.hasPrefix("hail-") ? "hail-buffer" : $0 } }
        }
        #expect(normalized(guarded) == normalized(plain.runner.calls))
    }
}
