#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

extension AmbientRouterStreamTargetTests {
    @Test func aFuturePersonaLessOnChangeRetainsItsTargetBeforeTheClipGuard() async throws {
        let fake = try FakeRightyo("/bin/cat > /dev/null")
        defer { fake.cleanUp() }
        let env = try await preboundAmbientRig(fake, timing: .init(eofGrace: 0.1, termGrace: 0.1))
        let pair = try await FallbackSocketPair.boundedConnect(port: env.port, selecting: ["recipient:other"])
        defer { pair.close() }
        let connection = try #require(await env.listener.peers.values.first?.session.connectionID)
        let router = env.router, stream = UUID(), token = UUID(), meeting = UUID()
        router.ambientAudio(.started(stream: stream, connection: connection, target: RecipientTestRig.target,
                                     binding: "reply-binding"))
        router.state.withLock { state in
            state.meeting[connection] = AmbientMeetingTimer(
                token: token, timer: Task {}, profile: .meeting, started: Date(), meetingID: meeting,
                expiresAt: Date().addingTimeInterval(60), recording: false, armed: 1)
            // Future on-change guard only: production restores use resumed_unrecorded, which has a persona.
            // A future persona-less on-change must still retain its eventual timeout destination.
            let change = AmbientMeetingChange(on: true, profile: .meeting, reason: "moved", reported: 0,
                                              token: token, meetingID: meeting, recording: false)
            #expect(change.persona == nil)
            router.meetingChanged(change, connection: connection, in: &state)
            state.streamTargets[connection] = nil
        }
        let clips = try #require(router.state.withLock { $0.privacyClips[connection] })
        await bounded("persona-less selection resolved") { await clips.queued {}.value }
        #expect(router.state.withLock { $0.meeting[connection]?.target == "recipient:other" })
        router.ambientAudio(.ended(stream: stream, reason: .final))
        await boundedSettle(router)
        await env.listener.stop()
    }

    @Test func aRefusedLateStartRetainsLatestButNeverAnAdmittedTarget() async throws {
        let fake = try FakeRightyo("/bin/cat > /dev/null")
        defer { fake.cleanUp() }
        let env = try await ambientRig(fake, timing: .init(eofGrace: 0.1, termGrace: 0.1))
        let pair = try await FallbackSocketPair.boundedConnect(port: env.port, selecting: [RecipientTestRig.target])
        defer { pair.close() }
        let connection = try #require(await env.listener.peers.values.first?.session.connectionID)
        let router = env.router
        #expect(await env.listener.ambientClipTarget(connection: connection) == RecipientTestRig.target)
        router.ambientAudio(.started(stream: UUID(), connection: connection, target: "recipient:other",
                                     binding: "other-binding"))
        #expect(await env.listener.ambientClipTarget(connection: connection) == RecipientTestRig.target)
        pair.close()
        #expect(await eventually { await env.listener.peers.isEmpty })
        #expect(await eventually {
            router.state.withLock { $0.runs.isEmpty && !$0.closed.contains(connection) }
        })
        let late = UUID()
        router.ambientAudio(.started(stream: late, connection: connection, target: "recipient:other"))
        #expect(router.state.withLock { $0.streamTargets[connection] == nil && $0.latest[connection] == late })
        #expect(await env.listener.ambientClipTarget(connection: connection) == nil)
        #expect(router.activeStream == nil)
        await env.listener.stop()
    }

    @Test func aMeetingWithoutARetainedTargetTimesOutWithoutAClip() async throws {
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
        #expect(await env.listener.ambientClipTarget(connection: connection) == RecipientTestRig.target)
        #expect(router.setMeeting(on: false, connection: connection, reason: "timeout", expected: token) == 1)
        #expect(!router.meetingMode(connection: connection))
        #expect(router.state.withLock { $0.privacyClips[connection] == nil })
        try await pair.boundedBarrier(step: "timeout without a target queues no clip")
        router.ambientAudio(.ended(stream: stream, reason: .final))
        await boundedSettle(router)
        await env.listener.stop()
    }

    @Test func privacyPreArmAndDeviceOffUseSelectionWithoutAStream() async throws {
        let fake = try FakeRightyo("/bin/cat > /dev/null")
        defer { fake.cleanUp() }
        let env = try await ambientRig(fake, timing: .init(eofGrace: 0.1, termGrace: 0.1))
        let pair = try await FallbackSocketPair.boundedConnect(port: env.port, selecting: [RecipientTestRig.target])
        defer { pair.close() }
        let connection = try #require(await env.listener.peers.values.first?.session.connectionID)
        let router = env.router
        router.ambientPrivacyPreArm(connection: connection)
        #expect(router.duckMode(connection: connection))
        #expect(await env.listener.ambientClipTarget(connection: connection) == RecipientTestRig.target)
        router.ambientPrivacy(false, connection: connection)
        #expect(!router.duckMode(connection: connection))
        #expect(await env.listener.ambientClipTarget(connection: connection) == RecipientTestRig.target)
        try await pair.boundedBarrier(step: "pre-arm and unreported off send no clip")
        await env.listener.stop()
    }
}
#endif
