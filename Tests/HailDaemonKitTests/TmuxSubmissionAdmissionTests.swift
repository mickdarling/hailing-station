#if os(macOS)
import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1))) struct TmuxSubmissionAdmissionTests {
    enum Retirement: CaseIterable { case peer, policy, caller }

    @Test(arguments: Retirement.allCases, [false, true])
    func admittedPasteCompletesBeforeTheNextSubmissionIsRefused(retirement: Retirement, framed: Bool) async throws {
        let fixture = try SlowTmuxCommandFixture()
        defer { fixture.release() }
        let rig = try submissionRig(fixture)
        let text = framed ? try PastedContent.frame(spoken: "synthetic input", pasted: "synthetic data")
            : "synthetic input"
        let delivery = Task {
            try await rig.adapter.deliver(text, to: "codex", binding: SlowTmuxCommandFixture.binding,
                                          authority: rig.authority)
        }
        try await fixture.wait("paste-started")
        switch retirement {
        case .peer: rig.peer.retire()
        case .policy: rig.policy.retire("tmux:codex")
        case .caller: delivery.cancel()
        }
        // Retirement/cancellation has returned while the admitted child is still at its barrier.
        #expect(!fixture.exists("paste-finished"))
        #expect(!fixture.exists("entered"))
        fixture.release()
        try await delivery.value
        #expect(fixture.lines("writes") == ["paste", "enter"])
        #expect(!fixture.exists("timed-out"))
        #expect(!rig.log.all.contains { $0.event == "tmux_policy_retired_unsent" || $0.event == "tmux_input_pending" })
        #expect(rig.log.all.contains { $0.event == "tmux_submit" })
        let launches = fixture.lines("launches").count
        let next = Task {
            if retirement == .caller { withUnsafeCurrentTask { $0?.cancel() } }
            try await rig.adapter.deliver("next input", to: "codex", binding: SlowTmuxCommandFixture.binding,
                                          authority: rig.authority)
        }
        await #expect(throws: (any Error).self) { try await next.value }
        #expect(fixture.lines("launches").count == launches)
        // A fresh delivery proves the pane has no sticky taint, independent of the retired grant.
        try fixture.mark("no-barrier")
        try await rig.adapter.deliver("clean evidence", to: "codex", binding: SlowTmuxCommandFixture.binding)
        #expect(fixture.lines("writes") == ["paste", "enter", "paste", "enter"])
        #expect(!rig.log.all.contains { $0.event == "tmux_input_pending" })
    }

    @Test(arguments: Retirement.allCases, [false, true])
    func retirementImmediatelyBeforeLaunchStartsNoWritingChild(retirement: Retirement, framed: Bool) async throws {
        let fixture = try SlowTmuxCommandFixture()
        let gate = RecipientPublicationGate(timeout: .seconds(15))
        defer { gate.release(); fixture.release() }
        let runner = ProcessCommandRunner(beforeLaunch: { arguments in
            if arguments.contains("paste-buffer") || arguments.contains(where: { $0.hasPrefix("paste-buffer ") }) {
                _ = gate.block(onDedicatedQueue: true)
            }
        })
        let rig = try submissionRig(fixture, runner: runner)
        let text = framed ? try PastedContent.frame(spoken: "synthetic input", pasted: "synthetic data")
            : "synthetic input"
        let sending = Task {
            try await rig.adapter.deliver(text, to: "codex", binding: SlowTmuxCommandFixture.binding,
                                          authority: rig.authority)
        }
        try await gate.waitEntered()
        let launches = fixture.lines("launches").count
        switch retirement {
        case .peer: rig.peer.retire()
        case .policy: rig.policy.retire("tmux:codex")
        case .caller: sending.cancel()
        }
        gate.release()
        await #expect(throws: (any Error).self) { try await sending.value }
        #expect(!gate.timedOut)
        #expect(fixture.lines("writes").isEmpty)
        #expect(fixture.lines("launches").count == launches + 1) // unused buffer deletion only
        #expect(fixture.exists("deleted"))
        #expect(rig.log.all.isEmpty)
    }

    @Test(arguments: [false, true])
    func admittedSubmissionKeepsItsConditionalRetryAfterRetirement(framed: Bool) async throws {
        let fixture = try SlowTmuxCommandFixture()
        defer { fixture.release() }
        try fixture.mark("retry")
        let rig = try submissionRig(fixture)
        let text = framed ? try PastedContent.frame(spoken: "synthetic input", pasted: "synthetic data")
            : "synthetic input"
        let sending = Task {
            try await rig.adapter.deliver(text, to: "codex", binding: SlowTmuxCommandFixture.binding,
                                          authority: rig.authority)
        }
        try await fixture.wait("paste-started")
        rig.peer.retire()
        fixture.release()
        try await sending.value
        #expect(fixture.lines("writes") == ["paste", "enter", "enter"])
        #expect(rig.log.all.contains { $0.event == "tmux_submit" && $0.detail.contains("retried") })
        let launches = fixture.lines("launches").count
        await #expect(throws: (any Error).self) {
            try await rig.adapter.deliver("next input", to: "codex", binding: SlowTmuxCommandFixture.binding,
                                          authority: rig.authority)
        }
        #expect(fixture.lines("launches").count == launches)
    }

    @Test func postLaunchAuthorityErrorRetainsExecutionEvidenceWithoutRetry() async throws {
        let fixture = try SlowTmuxCommandFixture()
        try fixture.mark("no-barrier")
        let rig = try submissionRig(fixture)
        let gate = DeliveryAdmission.Gate(validate: {}, perform: { operation in
            try operation()
            throw HostError.denied(.notAllowed("tmux:codex"))
        })
        let authority = DeliveryAuthority(admission: DeliveryAdmission(gates: [.targetPolicy: gate]))
        let failure = HeldSendFailure()
        failure.willHandoff()
        await #expect(throws: AdapterError.deliveryFailed("command launch completion was not confirmed")) {
            do {
                try await rig.adapter.deliver("synthetic input", to: "codex", binding: SlowTmuxCommandFixture.binding,
                                              authority: authority)
            } catch {
                failure.record(error)
                throw error
            }
        }
        #expect(failure.didAttemptHandoff)
        #expect(fixture.lines("writes") == ["paste"])
        #expect(await rig.adapter.lastTails["%2"] == PayloadTail("synthetic input"))
        await #expect(throws: AdapterError.inputPending(reason: .tainted)) {
            try await rig.adapter.deliver("later input", to: "codex", binding: SlowTmuxCommandFixture.binding)
        }
        #expect(fixture.lines("writes") == ["paste"])
    }

    enum Failure: CaseIterable { case enter, agent, binding }
    @Test(arguments: Failure.allCases)
    func admittedFailuresKeepStickyPendingInput(failure: Failure) async throws {
        let fixture = try SlowTmuxCommandFixture()
        defer { fixture.release() }
        let rig = try submissionRig(fixture)
        let text = try PastedContent.frame(spoken: "synthetic input", pasted: "synthetic data")
        let sending = Task {
            try await rig.adapter.deliver(text, to: "codex", binding: SlowTmuxCommandFixture.binding,
                                          authority: rig.authority)
        }
        try await fixture.wait("paste-started")
        let marker: String
        switch failure {
        case .enter: marker = "enter-fails"
        case .agent: marker = "left-agent"
        case .binding: marker = "rebound"
        }
        try fixture.mark(marker)
        fixture.release()
        await #expect(throws: AdapterError.self) { try await sending.value }
        try FileManager.default.removeItem(at: fixture.directory.appendingPathComponent(marker))
        let writes = fixture.lines("writes")
        await #expect(throws: AdapterError.inputPending(reason: .tainted)) {
            try await rig.adapter.deliver("later input", to: "codex", binding: SlowTmuxCommandFixture.binding)
        }
        #expect(fixture.lines("writes") == writes)
        #expect(rig.log.all.last?.event == "tmux_input_pending")
    }

}

private extension TmuxSubmissionAdmissionTests {
    struct Rig {
        let adapter: TmuxAdapter
        let policy: TargetPolicyAuthority
        let peer: ReplyTransportLifecycle
        let authority: DeliveryAuthority
        let log: EvidenceLog
    }

    func submissionRig(
        _ fixture: SlowTmuxCommandFixture, runner: ProcessCommandRunner = .init()
    ) throws -> Rig {
        var policy = Policy()
        try policy.allow("tmux:codex", binding: SlowTmuxCommandFixture.binding, tier: .open)
        let owner = TargetPolicyAuthority(store: InMemoryPolicyStore(policy))
        owner.update(policy)
        let peer = ReplyTransportLifecycle()
        let permit = try #require(peer.issuePermit())
        let stages = RetainedDeliveryStages(gates: [.peerLifecycle: RetainedDeliveryStages.gate {
            permit.performIfCurrent($0) == true
        }])
        let log = EvidenceLog()
        let timing = TmuxSubmitTiming(settleFloor: .zero, pollInterval: .milliseconds(1), quiet: .milliseconds(1),
                                      settleLimit: .seconds(1), confirmLimit: .seconds(1))
        let adapter = TmuxAdapter(runner: runner, tmux: fixture.executable, socket: "synthetic-socket",
                                  pollInterval: nil, submitTiming: timing, evidenceObserver: { log.append($0) })
        return Rig(adapter: adapter, policy: owner, peer: peer,
                   authority: stages.composed(policy: owner.snapshot(for: "tmux:codex")), log: log)
    }
}
#endif
