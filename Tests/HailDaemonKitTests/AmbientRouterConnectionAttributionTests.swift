#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// #327 PR 2b-i: connection commands read current selection, independently of admitted or refused streams.
extension AmbientRouterStreamTargetTests {
    @Test func aRefusedStartDoesNotOverrideTheConnectionsSelection() async throws {
        let fake = try FakeRightyo("/bin/cat > /dev/null")
        defer { fake.cleanUp() }
        let env = try await ambientRig(fake, timing: .init(eofGrace: 0.1, termGrace: 0.1))
        let pair = try await FallbackSocketPair.boundedConnect(port: env.port, selecting: [RecipientTestRig.target])
        defer { pair.close() }
        let connection = try #require(await env.listener.peers.values.first?.session.connectionID)
        let router = env.router, refused = UUID()
        router.ambientAudio(.started(stream: refused, connection: connection, target: "recipient:other"))
        #expect(router.state.withLock {
            $0.latest[connection] == refused && $0.newestStart == refused && $0.streamTargets[connection] == nil
        })
        #expect(router.activeStream == nil)
        #expect(await env.listener.ambientClipTarget(connection: connection) == RecipientTestRig.target)
        _ = try await receiveFrame(on: pair.sockets[0], step: "binding refusal")
        try await pair.boundedSelect("recipient:other", on: 0)
        #expect(await env.listener.ambientClipTarget(connection: connection) == "recipient:other")
        await env.listener.stop()
    }

    @Test func anUnknownSelectionSuppressesClipsButStillChangesState() async throws {
        let fake = try FakeRightyo("/bin/cat > /dev/null")
        defer { fake.cleanUp() }
        let env = try await ambientRig(fake, timing: .init(eofGrace: 0.1, termGrace: 0.1),
                                       acknowledgements: MeetingRig.clips)
        let pair = try await FallbackSocketPair.boundedConnect(port: env.port, selecting: [nil])
        defer { pair.close() }
        let connection = try #require(await env.listener.peers.values.first?.session.connectionID)
        let router = env.router
        #expect(await env.listener.ambientClipTarget(connection: connection) == nil)
        router.ambientPrivacyPreArm(connection: connection)
        #expect(router.duckMode(connection: connection))
        router.ambientPrivacy(false, connection: connection)
        #expect(!router.duckMode(connection: connection))
        #expect(router.setMeeting(on: true, connection: connection, reason: "voice") == 0)
        #expect(router.meetingMode(connection: connection))
        let clips = try #require(router.state.withLock { $0.privacyClips[connection] })
        await bounded("unselected entry resolved") { await clips.queued {}.value }
        #expect(router.state.withLock { $0.meeting[connection]?.target == nil })
        router.setMeeting(on: false, connection: connection, reason: "voice")
        #expect(!router.meetingMode(connection: connection))
        await bounded("unselected exit resolved") { await clips.queued {}.value }
        await bounded("unselected notices drained") { await router.mediaNotices.queued {}.value }
        try await pair.boundedBarrier(step: "unselected commands apply silently")
        await env.listener.stop()
    }

    @Test func aConnectionMeetingOffResolvesSelectionWhenItsTaskRuns() async throws {
        let rig = try await MeetingRig()
        defer { rig.close() }
        _ = try await rig.confirmation()
        let router = rig.env.router, connection = try #require(rig.connection()), target = "recipient:other"
        let held = MeetingLatch()
        defer { held.open() }
        router.enqueuePrivacyClip(connection) { _ in { await held.wait() } }
        #expect(router.setMeeting(on: false, connection: connection, reason: "voice") == 1)
        #expect(!router.meetingMode(connection: connection))
        try await rig.pair.boundedSelect(target, on: 0)
        held.open()
        await rig.drainMeetingChanges()
        let text = try await receiveFrame(on: rig.socket, step: "connection-selected meeting off")
        let audio = try await receiveFrame(on: rig.socket, step: "connection-selected meeting off audio")
        #expect(text.target == target && audio.target == target)
        if case .text(let words) = text.payload {
            #expect(words.text == MeetingRig.off.text && words.reply?.targetID == target)
        } else { Issue.record("expected meeting off confirmation") }
        try await rig.pair.boundedBarrier(step: "no extra frames")
        await rig.finish()
    }

    @Test func aSelectionChangeAfterResolutionSuppressesDelivery() async throws {
        let fake = try FakeRightyo("/bin/cat > /dev/null")
        defer { fake.cleanUp() }
        let env = try await ambientRig(fake, timing: .init(eofGrace: 0.1, termGrace: 0.1))
        let pair = try await FallbackSocketPair.boundedConnect(port: env.port, selecting: [RecipientTestRig.target])
        defer { pair.close() }
        let connection = try #require(await env.listener.peers.values.first?.session.connectionID)
        let target = try #require(await env.listener.ambientClipTarget(connection: connection))
        try await pair.boundedSelect("recipient:other", on: 0)
        #expect(await env.listener.acknowledgeAmbient(connection: connection, target: target, clip: MeetingRig.off)
                == "not_ready")
        try await pair.boundedBarrier(step: "selection change suppresses resolved clip")
        await env.listener.stop()
    }

    @Test func aDeviceEntryWithoutSelectionStillClosesItsPrivacyLedger() async throws {
        let rig = try await DuckRig(saying: "Rightyo, stop recording.", advertises: true,
                                    clips: AmbientDuckModeTests.clips)
        defer { rig.close() }
        _ = try await rig.confirmation()
        _ = try await receiveFrame(on: rig.socket, step: "initial privacy audio")
        let router = rig.env.router, connection = try #require(rig.connection())
        let session = try #require(await rig.env.listener.peers.values.first?.session)
        // Synthetic unknown selection after a child has started; no existing fixture is modified.
        await session.clearSelectionForAttributionTest()
        router.ambientPrivacy(false, connection: connection)
        #expect(!router.duckMode(connection: connection))
        router.ambientPrivacy(true, connection: connection)
        #expect(router.duckMode(connection: connection))
        let clips = try #require(router.state.withLock { $0.privacyClips[connection] })
        await bounded("nil-target entry closes") { await clips.queued {}.value }
        #expect(router.state.withLock { $0.privacy[connection]?.entries.isEmpty == true })
        try await barrier(on: rig.socket, step: "unknown selection sends no privacy clip")
        router.ambientAudio(.ended(stream: rig.stream, reason: .final))
        await rig.finish()
    }

    @Test func devicePrivacyOffUsesCurrentSelectionInsteadOfTheChildTarget() async throws {
        let rig = try await DuckRig(saying: "Rightyo, stop recording.", advertises: true,
                                    clips: AmbientDuckModeTests.clips)
        defer { rig.close() }
        _ = try await rig.confirmation()
        _ = try await receiveFrame(on: rig.socket, step: "initial privacy audio")
        let router = rig.env.router, connection = try #require(rig.connection()), target = "recipient:other"
        try await recipientSocketSend(sessionFrame(payload: .control(.select(targetID: target))), on: rig.socket)
        try await barrier(on: rig.socket, step: "new selection before device off")
        router.ambientPrivacy(false, connection: connection)
        #expect(!router.duckMode(connection: connection))
        let text = try await receiveFrame(on: rig.socket, step: "connection-selected privacy off")
        let audio = try await receiveFrame(on: rig.socket, step: "connection-selected privacy off audio")
        #expect(text.target == target && audio.target == target)
        if case .text(let words) = text.payload { #expect(words.reply?.targetID == target) } else {
            Issue.record("expected privacy off confirmation")
        }
        router.ambientAudio(.ended(stream: rig.stream, reason: .final))
        await rig.finish()
    }
}

private extension HostSession {
    func clearSelectionForAttributionTest() { selectedTarget = nil }
}
#endif
