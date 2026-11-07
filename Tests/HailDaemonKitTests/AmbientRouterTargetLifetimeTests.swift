#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

extension AmbientRouterStreamTargetTests {
    @Test func aPersonaLessMeetingRestoreRetainsItsTargetBeforeTheClipGuard() async throws {
        let fake = try FakeRightyo("/bin/cat > /dev/null")
        defer { fake.cleanUp() }
        let env = try await ambientRig(fake, timing: .init(eofGrace: 0.1, termGrace: 0.1), preboundOtherTarget: true)
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

    @Test func aPrunedClosedConnectionNeverRegainsAStreamTarget() async throws {
        let fake = try FakeRightyo("/bin/cat > /dev/null")
        defer { fake.cleanUp() }
        let env = try await ambientRig(fake, timing: .init(eofGrace: 0.1, termGrace: 0.1))
        let pair = try await FallbackSocketPair.boundedConnect(port: env.port, selecting: [RecipientTestRig.target])
        defer { pair.close() }
        let connection = try #require(await env.listener.peers.values.first?.session.connectionID)
        let router = env.router
        #expect(router.streamTarget(on: connection) == nil)
        router.ambientAudio(.started(stream: UUID(), connection: connection, target: "recipient:other",
                                     binding: "other-binding"))
        #expect(router.streamTarget(on: connection) == "recipient:other")
        pair.close()
        #expect(await eventually { await env.listener.peers.isEmpty })
        #expect(await eventually {
            router.state.withLock { $0.runs.isEmpty && !$0.closed.contains(connection) }
        })
        router.ambientAudio(.started(stream: UUID(), connection: connection, target: "recipient:other"))
        #expect(router.state.withLock { $0.streamTargets[connection] == nil })
        #expect(router.streamTarget(on: connection) == nil)
        await env.listener.stop()
    }

    @Test func aTargetlessMeetingTimeoutDoesNotBorrowTheCurrentStreamTarget() async throws {
        let fake = try FakeRightyo("/bin/cat > /dev/null")
        defer { fake.cleanUp() }
        let env = try await ambientRig(fake, timing: .init(eofGrace: 0.1, termGrace: 0.1),
                                       acknowledgements: MeetingRig.clips, replyControl: true,
                                       preboundOtherTarget: true)
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
        #expect(router.state.withLock { $0.privacyClips[connection] == nil })
        try await pair.boundedBarrier(step: "targetless timeout stays silent")
        router.ambientAudio(.ended(stream: stream, reason: .final))
        await boundedSettle(router)
        await env.listener.stop()
    }

    @Test func privacyPreArmAndDeviceOffWorkWithoutGuessingATarget() async throws {
        let fake = try FakeRightyo("/bin/cat > /dev/null")
        defer { fake.cleanUp() }
        let env = try await ambientRig(fake, timing: .init(eofGrace: 0.1, termGrace: 0.1))
        let pair = try await FallbackSocketPair.boundedConnect(port: env.port, selecting: [RecipientTestRig.target])
        defer { pair.close() }
        let connection = try #require(await env.listener.peers.values.first?.session.connectionID)
        let router = env.router
        router.ambientPrivacyPreArm(connection: connection)
        #expect(router.duckMode(connection: connection))
        #expect(router.streamTarget(on: connection) == nil)
        router.ambientPrivacy(false, connection: connection)
        #expect(!router.duckMode(connection: connection))
        #expect(router.streamTarget(on: connection) == nil)
        try await pair.boundedBarrier(step: "targetless privacy sends no guessed clip")
        await env.listener.stop()
    }
}
#endif
