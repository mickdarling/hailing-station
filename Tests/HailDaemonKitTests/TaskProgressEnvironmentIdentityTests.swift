import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

private struct UnusedProgressRenderer: SessionUpdateSpeechRendering {
    func render(_ text: String, publish: @Sendable (Data, Bool) async throws -> Void) async throws {
        Issue.record("identity regression must not invoke a renderer")
    }
}

/// Real listener identity/readiness checks under a retained speech fence. No transport I/O, microphone,
/// provider, wall-clock sleep or model polling is involved.
@Suite(.serialized, .timeLimit(.minutes(1))) struct TaskProgressEnvironmentIdentityTests {
    private func holdPlayback(_ listener: WebSocketListener)
        async -> (SessionUpdateFence, AsyncStream<Void>.Continuation) {
        let release = AsyncStream<Void>.makeStream()
        await listener.configureSessionUpdateSpeech(UnusedProgressRenderer())
        let fence = await listener.sessionUpdateFence
        fence.startSpeech { _ in for await _ in release.stream { break } }
        return (fence, release.continuation)
    }

    @Test func knownPlaybackKeepsIdentityAndCleanupResumesForAFullInterval() async throws {
        let clock = ProgressTestClock(), wiring = TaskProgressHostIntegrationTests.Wiring()
        let rig = try await SessionUpdateListenerRig.make(ambient: wiring)
        wiring.owner.withLock { $0 = rig.connectionID }
        await rig.listener.enableTaskProgress(clock: clock.clock)
        let (fence, release) = await holdPlayback(rig.listener)
        let environment = await rig.listener.taskProgressEnvironment(for: RecipientTestRig.target)
        #expect(fence.speechBusy && environment.playback)
        #expect(environment.uniqueRecipient && environment.pauseReason == .playback)
        #expect(await rig.listener.taskProgressControlConnection(for: RecipientTestRig.target) == rig.connectionID)
        #expect(await rig.listener.taskProgressConnection(for: RecipientTestRig.target) == nil)
        let started = await rig.listener.taskProgress(.init(action: .start, target: RecipientTestRig.target,
                                                           task: UUID(), seconds: 60))
        #expect(started.pauseReason == "playback" && started.nextDueInSeconds == nil)
        #expect(clock.sleeps == 0)
        clock.advance(by: .seconds(600))
        release.yield(())
        release.finish()
        await fence.joinSpeech()
        let resumed = await rig.listener.taskProgress(.init(action: .status))
        #expect(resumed.pauseReason == nil && resumed.nextDueInSeconds == 60)
        #expect(resumed.outstanding == false)
        #expect(await rig.hostRig.adapter.legacy.isEmpty)
        await rig.listener.stop()
    }

    @Test func playbackDoesNotHideAnUnavailableRecipientOrGrantDeadlineReadiness() async throws {
        let clock = ProgressTestClock(), wiring = TaskProgressHostIntegrationTests.Wiring()
        let rig = try await SessionUpdateListenerRig.make(ambient: wiring)
        wiring.owner.withLock { $0 = rig.connectionID }
        await rig.listener.enableTaskProgress(clock: clock.clock)
        let (fence, release) = await holdPlayback(rig.listener)
        await rig.session.removeTaskProgressUpdateCapability()
        // The early readiness check says playback, but the independent exact-peer identity check must refuse it.
        #expect(await rig.listener.sessionUpdatePauseReason(for: RecipientTestRig.target) == "playback")
        #expect(await rig.listener.taskProgressControlConnection(for: RecipientTestRig.target) == nil)
        let environment = await rig.listener.taskProgressEnvironment(for: RecipientTestRig.target)
        #expect(environment.playback && !environment.uniqueRecipient)
        #expect(environment.pauseReason == .ambiguousRecipient)
        let started = await rig.listener.taskProgress(.init(action: .start, target: RecipientTestRig.target,
                                                           task: UUID(), seconds: 60))
        #expect(started.pauseReason == "ambiguousRecipient" && started.nextDueInSeconds == nil)
        release.yield(())
        release.finish()
        await fence.joinSpeech()
        #expect(await rig.listener.sessionUpdatePauseReason(for: RecipientTestRig.target) == "unavailable_recipient")
        let unavailable = await rig.listener.taskProgressEnvironment(for: RecipientTestRig.target)
        #expect(!unavailable.playback && !unavailable.uniqueRecipient)
        #expect(unavailable.pauseReason == .ambiguousRecipient)
        #expect(await rig.listener.taskProgress(.init(action: .status)).nextDueInSeconds == nil)
        #expect(clock.sleeps == 0)
        await rig.listener.stop()
    }
}

private extension HostSession {
    func removeTaskProgressUpdateCapability() { peerCapabilities.remove(SessionUpdateCard.capability) }
}
