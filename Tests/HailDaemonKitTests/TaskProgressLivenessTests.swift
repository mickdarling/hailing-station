import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit

private final class HeldLivenessRenderer: SessionUpdateSpeechRendering {
    let started = AsyncStream<Void>.makeStream()
    let release = AsyncStream<Void>.makeStream()
    let cleaned = Mutex(false)

    func render(_ text: String, publish: @Sendable (Data, Bool) async throws -> Void) async throws {
        defer { cleaned.withLock { $0 = true } }
        started.continuation.yield(())
        for await _ in release.stream { break }
        try Task.checkCancellation()
        try await publish(Data(repeating: 0, count: 480), true)
    }
}

/// Injected deadlines plus actual listener renderer/router transitions. No owner interaction, diagnostic
/// subscription, model polling, wall-clock sleep, microphone or physical playback is used to resume cadence.
@Suite(.serialized, .timeLimit(.minutes(1))) struct TaskProgressLivenessTests {
    private func paused(_ listener: WebSocketListener, reason: String) async throws -> LocalTaskProgressReport {
        // Bound executor turns, not elapsed time: the due task must get its actor turn before assertions.
        for _ in 0..<1_000 {
            let status = await listener.taskProgress(.init(action: .status))
            if status.pauseReason == reason, status.outstanding == false { return status }
            await Task.yield()
        }
        Issue.record("due callback did not reach expected pause: \(reason)")
        return await listener.taskProgress(.init(action: .status))
    }

    @Test func rendererCleanupRearmsAPausedDueWakeForAFullInterval() async throws {
        let clock = ProgressTestClock(), wiring = TaskProgressHostIntegrationTests.Wiring()
        let rig = try await SessionUpdateListenerRig.make(ambient: wiring, audio: true)
        wiring.owner.withLock { $0 = rig.connectionID }
        await rig.listener.enableTaskProgress(clock: clock.clock)
        let renderer = HeldLivenessRenderer()
        await rig.listener.configureSessionUpdateSpeech(renderer)
        var due = clock.scheduled.stream.makeAsyncIterator()
        var started = renderer.started.stream.makeAsyncIterator()
        var prompts = rig.hostRig.adapter.legacyEvents.stream.makeAsyncIterator()
        let enrollment = await rig.listener.taskProgress(.init(action: .start, target: RecipientTestRig.target,
                                                               task: UUID(), seconds: 60))
        #expect(enrollment.nextDueInSeconds == 60)
        _ = try #require(await due.next())
        _ = await rig.listener.sessionUpdate(.init(action: .submit, target: RecipientTestRig.target,
                                                   priority: .action, text: "Synthetic unrelated completion"))
        _ = try #require(await started.next())
        clock.advance(by: .seconds(60))
        #expect(try await paused(rig.listener, reason: "playback").nextDueInSeconds == nil)
        clock.advance(by: .seconds(600))
        #expect(await rig.hostRig.adapter.legacy.isEmpty)
        renderer.release.continuation.yield(())
        renderer.release.continuation.finish()
        let fence = await rig.listener.sessionUpdateFence
        await fence.joinSpeech()
        #expect(renderer.cleaned.withLock { $0 }, "availability changes only after renderer cleanup")
        let resumed = await rig.listener.taskProgress(.init(action: .status))
        #expect(resumed.pauseReason == nil && resumed.nextDueInSeconds == 60 && resumed.outstanding == false)
        clock.advance(by: .seconds(59))
        #expect(await rig.hostRig.adapter.legacy.isEmpty)
        clock.advance(by: .seconds(1))
        _ = try #require(await prompts.next())
        #expect(await rig.hostRig.adapter.legacy.count == 1, "missed ticks do not accumulate")
        await rig.listener.stop()
    }

    @Test func realPublicAmbientStartAndEndRefreshWithoutReplyDiagnostics() async throws {
        let fake = try FakeRightyo("/bin/cat > /dev/null")
        defer { fake.cleanUp() }
        let clock = ProgressTestClock()
        let router = AmbientRightyoRouter(configuration: .init(executable: fake.executable, config: fake.config,
            target: RecipientTestRig.target, binding: "reply-binding", allowSynthetic: true,
            timing: .init(eofGrace: 20, termGrace: 20), replyControl: false))
        let rig = try await SessionUpdateListenerRig.make(ambient: router)
        await rig.listener.enableTaskProgress(clock: clock.clock)
        let initial = await rig.listener.taskProgress(.init(action: .start, target: RecipientTestRig.target,
                                                           task: UUID(), seconds: 60))
        #expect(initial.pauseReason == "notListening" && initial.nextDueInSeconds == nil)
        #expect(clock.sleeps == 0)
        let first = UUID(), selection = await rig.session.selectionGeneration
        router.ambientAudio(.started(stream: first, connection: rig.connectionID, selection: selection))
        await router.taskProgressChanges.queued({}).value
        let listening = await rig.listener.taskProgress(.init(action: .status))
        #expect(router.activeConnection() == rig.connectionID)
        #expect(listening.pauseReason == nil && listening.nextDueInSeconds == 60)
        clock.advance(by: .seconds(30))
        router.ambientAudio(.ended(stream: first, reason: .final))
        await router.taskProgressChanges.queued({}).value
        let ended = await rig.listener.taskProgress(.init(action: .status))
        #expect(ended.pauseReason == "notListening" && ended.nextDueInSeconds == nil)
        clock.advance(by: .seconds(600))
        #expect(await rig.hostRig.adapter.legacy.isEmpty)
        let second = UUID()
        router.ambientAudio(.started(stream: second, connection: rig.connectionID, selection: selection))
        await router.taskProgressChanges.queued({}).value
        let restarted = await rig.listener.taskProgress(.init(action: .status))
        #expect(restarted.pauseReason == nil && restarted.nextDueInSeconds == 60)
        let pipeline = try #require(router.activePipeline)
        router.inputClosed(second, pipeline: pipeline)
        await router.taskProgressChanges.queued({}).value
        #expect(await rig.listener.taskProgress(.init(action: .status)).pauseReason == "notListening")
        await rig.listener.stop()
    }

    @Test func anActiveChildFailurePausesWithoutAnotherAudioSegmentOrDiagnostic() async throws {
        let fake = try FakeRightyo("/bin/cat > /dev/null\nexit 2")
        defer { fake.cleanUp() }
        let clock = ProgressTestClock()
        let router = AmbientRightyoRouter(configuration: .init(executable: fake.executable, config: fake.config,
            target: RecipientTestRig.target, binding: "reply-binding", allowSynthetic: true,
            timing: .init(eofGrace: 20, termGrace: 20), replyControl: false))
        let rig = try await SessionUpdateListenerRig.make(ambient: router)
        await rig.listener.enableTaskProgress(clock: clock.clock)
        _ = await rig.listener.taskProgress(.init(action: .start, target: RecipientTestRig.target,
                                                  task: UUID(), seconds: 60))
        router.ambientAudio(.started(stream: UUID(), connection: rig.connectionID,
                                    selection: await rig.session.selectionGeneration))
        await router.taskProgressChanges.queued({}).value
        #expect(await rig.listener.taskProgress(.init(action: .status)).nextDueInSeconds == 60)
        let pipeline = try #require(router.activePipeline)
        let run = try #require(router.state.withLock { state in
            state.active.flatMap { state.runs[$0.run]?.task }
        })
        pipeline.finishInput() // Only the actual child exit/run cleanup clears the active owner.
        await run.value
        await router.taskProgressChanges.queued({}).value
        let failed = await rig.listener.taskProgress(.init(action: .status))
        #expect(router.activeConnection() == nil)
        #expect(failed.pauseReason == "notListening" && failed.nextDueInSeconds == nil)
        clock.advance(by: .seconds(600))
        #expect(await rig.hostRig.adapter.legacy.isEmpty)
        await rig.listener.stop()
    }
}
