#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

extension AmbientRouterStreamTargetTests {
    @Test func aPersonaLessMeetingRestoreRetainsItsTargetBeforeTheClipGuard() async throws {
        let fake = try FakeRightyo("/bin/cat > /dev/null")
        defer { fake.cleanUp() }
        let env = try await preboundAmbientRig(fake, timing: .init(eofGrace: 0.1, termGrace: 0.1))
        let pair = try await FallbackSocketPair.boundedConnect(port: env.port, selecting: [RecipientTestRig.target])
        defer { pair.close() }
        let connection = try #require(await env.listener.peers.values.first?.session.connectionID)
        let router = env.router, stream = UUID(), token = UUID(), meeting = UUID()
        router.ambientAudio(.started(stream: stream, connection: connection, target: RecipientTestRig.target,
                                     binding: "reply-binding"))
        router.state.withLock { state in
            state.meeting[connection] = AmbientMeetingTimer(
                token: token, timer: Task {}, profile: .meeting, started: Date(), meetingID: meeting,
                expiresAt: Date().addingTimeInterval(60), recording: false, armed: 1)
            // A system restore/move with no spoken persona still owns its eventual timeout destination.
            let change = AmbientMeetingChange(on: true, profile: .meeting, reason: "moved", reported: 0,
                                              token: token, meetingID: meeting, recording: false)
            #expect(change.persona == nil)
            router.meetingChanged(change, connection: connection, in: &state)
            #expect(state.meeting[connection]?.target == RecipientTestRig.target)
            state.streamTargets[connection] = nil
        }
        #expect(router.state.withLock { $0.meeting[connection]?.target == RecipientTestRig.target })
        router.ambientAudio(.ended(stream: stream, reason: .final))
        await boundedSettle(router)
        await env.listener.stop()
    }

    @Test func aPrunedClosedConnectionCanRetainOnlyALateSnapshot() async throws {
        let fake = try FakeRightyo("/bin/cat > /dev/null")
        defer { fake.cleanUp() }
        let env = try await ambientRig(fake, timing: .init(eofGrace: 0.1, termGrace: 0.1))
        let pair = try await FallbackSocketPair.boundedConnect(port: env.port, selecting: [RecipientTestRig.target])
        defer { pair.close() }
        let connection = try #require(await env.listener.peers.values.first?.session.connectionID)
        let router = env.router
        #expect(router.streamTarget(on: connection) == router.configuration.target)
        router.ambientAudio(.started(stream: UUID(), connection: connection, target: "recipient:other",
                                     binding: "other-binding"))
        #expect(router.streamTarget(on: connection) == "recipient:other")
        pair.close()
        #expect(await eventually { await env.listener.peers.isEmpty })
        #expect(await eventually {
            router.state.withLock { $0.runs.isEmpty && !$0.closed.contains(connection) }
        })
        router.ambientAudio(.started(stream: UUID(), connection: connection, target: "recipient:other"))
        #expect(router.state.withLock { $0.streamTargets[connection] == "recipient:other" })
        #expect(router.activeStream == nil)
        await env.listener.stop()
    }

    @Test func aMeetingWithoutARetainedTargetTimesOutUsingOnlyTheConfiguredFallback() async throws {
        let fake = try FakeRightyo("/bin/cat > /dev/null")
        defer { fake.cleanUp() }
        let env = try await preboundAmbientRig(fake, timing: .init(eofGrace: 0.1, termGrace: 0.1),
                                               acknowledgements: MeetingRig.clips)
        let pair = try await FallbackSocketPair.boundedConnect(port: env.port, selecting: [RecipientTestRig.target])
        defer { pair.close() }
        let connection = try #require(await env.listener.peers.values.first?.session.connectionID)
        let router = env.router, stream = UUID(), token = UUID()
        router.ambientAudio(.started(stream: stream, connection: connection, target: RecipientTestRig.target,
                                     binding: "reply-binding"))
        router.state.withLock { state in
            state.meeting[connection] = AmbientMeetingTimer(
                token: token, timer: Task {}, profile: .meeting, started: Date(), meetingID: UUID(),
                expiresAt: Date(), recording: false, armed: 1)
        }
        #expect(router.streamTarget(on: connection) == RecipientTestRig.target)
        #expect(router.setMeeting(on: false, connection: connection, reason: "timeout", expected: token) == 1)
        let clips = try #require(router.state.withLock { $0.privacyClips[connection] })
        await bounded("timeout clip drained") { await clips.queued {}.value }
        // The session selects the current stream, not the configured fallback: delivery must fail closed.
        try await pair.boundedBarrier(step: "timeout fallback cannot borrow current stream target")
        router.ambientAudio(.ended(stream: stream, reason: .final))
        await boundedSettle(router)
        await env.listener.stop()
    }

    @Test func privacyPreArmAndDeviceOffRetainTheConfiguredFallback() async throws {
        let fake = try FakeRightyo("/bin/cat > /dev/null")
        defer { fake.cleanUp() }
        let env = try await ambientRig(fake, timing: .init(eofGrace: 0.1, termGrace: 0.1))
        let pair = try await FallbackSocketPair.boundedConnect(port: env.port, selecting: [RecipientTestRig.target])
        defer { pair.close() }
        let connection = try #require(await env.listener.peers.values.first?.session.connectionID)
        let router = env.router
        router.ambientPrivacyPreArm(connection: connection)
        #expect(router.duckMode(connection: connection))
        #expect(router.streamTarget(on: connection) == router.configuration.target)
        router.ambientPrivacy(false, connection: connection)
        #expect(!router.duckMode(connection: connection))
        #expect(router.streamTarget(on: connection) == router.configuration.target)
        try await pair.boundedBarrier(step: "pre-arm and unreported off send no clip")
        await env.listener.stop()
    }
}
#endif
