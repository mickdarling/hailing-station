#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// #327 PR 2a: start a prebound non-configured stream, then use its child callback builders and change/clear the
/// connection snapshot before invoking them. Real loopback delivery checks the selected target and policy.
extension AmbientRouterStreamTargetTests {
    enum MeetingConfirmation: CaseIterable { case entry, exit, timeout }

    @Test(arguments: MeetingConfirmation.allCases, [false, true])
    func meetingCallbacksKeepTheirStreamTarget(_ confirmation: MeetingConfirmation, clear: Bool) async throws {
        let rig = try await MeetingRig(preboundOtherTarget: true)
        defer { rig.close() }
        _ = try await rig.confirmation()
        let router = rig.env.router, connection = try #require(rig.connection())
        // The child really started with a pre-admission binding for a target other than the configured one.
        let target = RecipientTestRig.target
        #expect(router.state.withLock { $0.active?.target == target && $0.active?.binding == "reply-binding" }
                && target != router.configuration.target)
        let callback = router.voiceMeeting(on: connection, target: target, listener: rig.env.listener)
        let held = MeetingLatch()
        defer { held.open() }
        router.enqueuePrivacyClip(connection) { _ in { await held.wait() } }
        // No active stream now: a lookup at callback time or playback would see B (or no target).
        let active = router.state.withLock { state in
            let active = state.active
            state.active = nil
            state.streamTargets[connection] = clear ? nil : router.configuration.target
            return active
        }
        switch confirmation {
        case .entry: callback(true, .meeting)
        case .exit: callback(false, .meeting)
        case .timeout:
            callback(true, .meeting)
            let token = try #require(router.state.withLock { $0.meeting[connection]?.token })
            #expect(router.setMeeting(on: false, connection: connection, reason: "timeout", expected: token) == 1)
        }
        held.open()
        let text = try await receiveFrame(on: rig.socket, step: "stream-owned meeting confirmation")
        let audio = try await receiveFrame(on: rig.socket, step: "stream-owned meeting audio")
        let expected: AmbientAckClip = switch confirmation {
        case .entry: MeetingRig.on
        case .exit: MeetingRig.off
        case .timeout: MeetingRig.ended
        }
        #expect(text.target == target && audio.target == target)
        if case .text(let words) = text.payload { #expect(words.text == expected.text) } else {
            Issue.record("expected meeting confirmation text")
        }
        router.state.withLock { $0.active = active }
        router.ambientAudio(.ended(stream: rig.stream, reason: .final))
        await rig.finish()
    }

    enum PrivacyConfirmation: CaseIterable {
        case enter, exit, status, hint, unverified, stillRecording, unavailable, meeting
    }

    @Test(arguments: PrivacyConfirmation.allCases, [false, true])
    func privacyCallbacksKeepTheirStreamTarget(_ confirmation: PrivacyConfirmation, clear: Bool) async throws {
        let rig = try await DuckRig(saying: "Rightyo, stop recording.", advertises: true,
                                    clips: AmbientDuckModeTests.clips, preboundOtherTarget: true)
        defer { rig.close() }
        _ = try await rig.confirmation()
        _ = try await receiveFrame(on: rig.socket, step: "initial privacy audio")
        let router = rig.env.router, connection = try #require(rig.connection())
        // The child really started with a pre-admission binding for a target other than the configured one.
        let target = RecipientTestRig.target
        #expect(router.state.withLock { $0.active?.target == target && $0.active?.binding == "reply-binding" }
                && target != router.configuration.target)
        try await recipientSocketSend(sessionFrame(payload: .control(.select(targetID: target))), on: rig.socket)
        try await barrier(on: rig.socket, step: "originating stream selection")
        let duck = router.voiceDuck(on: connection, target: target, listener: rig.env.listener)
        let meeting = router.voiceMeeting(on: connection, target: target, listener: rig.env.listener)
        let held = MeetingLatch()
        defer { held.open() }
        router.enqueuePrivacyClip(connection) { _ in { await held.wait() } }
        let active = router.state.withLock { state in
            let active = state.active
            state.active = nil
            state.streamTargets[connection] = clear ? nil : router.configuration.target
            if confirmation == .unavailable, let active {
                // No listening keeper or earlier announcement: the child's unavailable changes the last word.
                state.runs[active.run]?.retiredAt = 1
                state.privacy[connection] = .init()
            }
            return active
        }
        invoke(confirmation, duck: duck, meeting: meeting)
        held.open()
        let text = try await receiveFrame(on: rig.socket, step: "stream-owned privacy confirmation")
        let audio = try await receiveFrame(on: rig.socket, step: "stream-owned privacy audio")
        #expect(text.target == target && audio.target == target)
        if case .text = text.payload {} else { Issue.record("expected privacy confirmation text") }
        if case .audio = audio.payload {} else { Issue.record("expected privacy confirmation audio") }
        router.state.withLock { state in
            state.active = active
            if let active { state.runs[active.run]?.retiredAt = nil }
        }
        router.ambientAudio(.ended(stream: rig.stream, reason: .final))
        await rig.finish()
    }
    private func invoke(_ confirmation: PrivacyConfirmation, duck: @Sendable (PrivacyCommand) -> Void,
                        meeting: @Sendable (Bool, MeetingProfile?) -> Void) {
        switch confirmation {
        case .enter: duck(.enter)
        case .exit: duck(.exit)
        case .status: duck(.status)
        case .hint: duck(.hint)
        case .unverified: duck(.unverified)
        case .stillRecording: duck(.stillRecording)
        case .unavailable: duck(.unavailable)
        case .meeting: meeting(true, .meeting)
        }
    }
}
#endif
