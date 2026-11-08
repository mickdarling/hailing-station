import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct TaskProgressTmuxAdmissionTests {
    private static let binding = "$2@1758230001/%2:502"

    @Test(arguments: [false, true])
    func wakeAttemptCommitsOnlyAtPasteAdmission(tainted: Bool) async throws {
        let attempt = TaskProgressWakeAttempt()
        let barrier = TmuxCommandBarrier("set-buffer")
        defer { barrier.gate.fire() }
        let (adapter, runner) = try await makeAdapter(tainted: tainted, attempt: attempt, barrier: barrier)
        let rig = try await TaskProgressGuardedWakeRig.make(adapter: adapter, name: "codex", binding: Self.binding)
        let generation = rig.host.targetPolicy.snapshot(for: rig.target)
        let task = TaskProgressTask(session: rig.target, binding: Self.binding)
        let wake = TaskProgressWake(task: task, token: UUID())
        let retained = try await stages(rig, task: task, generation: generation, attempt: attempt)
        let before = await runner.calls.count
        let sending = Task {
            try await TaskProgressWakeScope.$retained.withValue(retained) {
                try await rig.host.sendAuthorized(wake.statusPrompt, policyGeneration: generation,
                                                  from: "task-progress", expectedBinding: Self.binding, context: nil)
            }
        }
        if tainted {
            await #expect(throws: AdapterError.inputPending(reason: .tainted)) { try await sending.value }
            #expect(!attempt.hasAttempt)
            let later = await runner.calls.dropFirst(before)
            #expect(!later.contains {
                $0.contains("capture-pane") || $0.contains("set-buffer")
                    || $0.contains("paste-buffer") || $0.contains("send-keys")
            })
            #expect(await runner.delivered == ["synthetic input", "Enter"])
        } else {
            try await barrier.gate.waitUntilSuspended()
            #expect(!attempt.hasAttempt, "buffer preparation does not commit a task attempt")
            #expect(await runner.delivered.isEmpty)
            #expect(try await barrier.gate.finish(sending) == .delivered([wake.statusPrompt]))
            #expect(attempt.hasAttempt)
            #expect(await runner.delivered == [wake.statusPrompt, "Enter"])
        }
        await rig.listener.stop()
    }

    @Test func wakeAttemptRemainsUncommittedBeforePasteLaunch() async throws {
        let attempt = TaskProgressWakeAttempt()
        let barrier = TmuxCommandBarrier("paste-buffer")
        defer { barrier.gate.fire() }
        let (adapter, runner) = try await makeAdapter(tainted: false, attempt: attempt, barrier: barrier)
        let rig = try await TaskProgressGuardedWakeRig.make(adapter: adapter, name: "codex", binding: Self.binding)
        let generation = rig.host.targetPolicy.snapshot(for: rig.target)
        let task = TaskProgressTask(session: rig.target, binding: Self.binding)
        let retained = try await stages(rig, task: task, generation: generation, attempt: attempt)
        let sending = Task {
            try await TaskProgressWakeScope.$retained.withValue(retained) {
                try await rig.host.sendAuthorized("synthetic input", policyGeneration: generation,
                                                  from: "task-progress", expectedBinding: Self.binding, context: nil)
            }
        }
        try await barrier.gate.waitUntilSuspended()
        #expect(!attempt.hasAttempt, "a recorded paste command has not yet entered launch admission")
        #expect(await runner.delivered.isEmpty)
        #expect(try await barrier.gate.finish(sending) == .delivered(["synthetic input"]))
        #expect(attempt.hasAttempt)
        #expect(await runner.delivered == ["synthetic input", "Enter"])
        await rig.listener.stop()
    }

    private func makeAdapter(
        tainted: Bool, attempt: TaskProgressWakeAttempt, barrier: TmuxCommandBarrier
    ) async throws -> (TmuxAdapter, FakeCommandRunner) {
        let pane = ScriptedPane()
        let establishingTaint = Mutex(tainted)
        let runner = FakeCommandRunner(beforeResponse: { arguments in
            if !establishingTaint.withLock({ $0 }) { await barrier.pause(arguments) }
        }, { arguments in
            if establishingTaint.withLock({ $0 }), arguments.last == "Enter" {
                return CommandResult(exitCode: 1, stdout: "", stderr: "synthetic refusal")
            }
            if arguments.contains("paste-buffer"), !establishingTaint.withLock({ $0 }) {
                #expect(attempt.hasAttempt, "the task attempt precedes the paste side effect")
            }
            return pane.respond(arguments)
        })
        let adapter = TmuxAdapter(runner: runner, pollInterval: nil, submitTiming: EvidenceHarness.timing(),
                                  submitClock: ManualSubmitClock().clock)
        if tainted {
            await #expect(throws: AdapterError.deliveryFailed("synthetic refusal")) {
                try await adapter.deliver("synthetic input", to: "codex", binding: Self.binding)
            }
            establishingTaint.withLock { $0 = false }
            pane.reset(baseline: ScriptedPane.oldScreen)
        }
        return (adapter, runner)
    }

    private func stages(
        _ rig: TaskProgressGuardedWakeRig, task: TaskProgressTask,
        generation: TargetPolicyGeneration, attempt: TaskProgressWakeAttempt
    ) async throws -> RetainedDeliveryStages {
        let publication = TaskProgressPublicationAuthority(generation: generation, binding: Self.binding,
                                                           taskFence: TaskProgressOutputFence())
        let revision = await rig.listener.taskProgressPrivacyRevision()
        let lifetime = TaskProgressAdmissionLifetime(expires: rig.clock.now.advanced(by: .seconds(60)),
                                                     clock: rig.clock.clock)
        return try #require(await rig.listener.taskProgressDeliveryStages(
            for: task, authority: publication, privacyRevision: revision, attempt: attempt, lifetime: lifetime
        ))
    }
}
