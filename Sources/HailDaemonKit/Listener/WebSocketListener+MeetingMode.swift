#if os(macOS)
public import Foundation

/// A connection's meeting state (#735 meeting mode (rightyo#227)): its guarded timeout, profile and original start.
struct AmbientMeetingTimer {
    let token: UUID
    let timer: Task<Void, Never>
    let profile: MeetingProfile
    let started: Date
}

/// Host-only meeting state (#735 meeting mode (rightyo#227)). Recording and a capability-gated device notice are
/// later slices; the owner's pause and the rest of RightyO's attention policy stay as they are.
extension AmbientRightyoRouter {
    public static let defaultMeetingTimeout: TimeInterval = 3 * 3600

    /// Whether the connection has a meeting, including the one-participant rubber duck profile.
    public func meetingMode(connection: UUID) -> Bool { state.withLock { $0.meeting[connection] != nil } }

    /// One swappable child write (#735 meeting mode (rightyo#227)): v1 reuses RightyO's media gate, whose attends
    /// need the assistant's name and the owner's authority, and which refuses every follow-up (`_media_attends`).
    /// It stays on while either host mode is on. A later capability-gated meeting control belongs here alone.
    @discardableResult
    func reportModes(to pipeline: RightyoAmbientPipeline, connection: UUID, in state: State) -> Bool {
        pipeline.reportMedia(state.media[connection] != nil || state.meeting[connection] != nil)
    }

    /// Tells every child under the caller's lock, as media mode does; a write never blocks.
    func reportModes(connection: UUID, in state: State) -> Int {
        state.runs.values.filter {
            $0.connection == connection && reportModes(to: $0.pipeline, connection: connection, in: state)
        }.count
    }

    /// The owner's meeting command, held back like media mode (#735 meeting mode (rightyo#227)). A private entry
    /// hears only the privacy status, and only after privacy was announced, decided on its own clip chain.
    func voiceMeeting(on connection: UUID, listener: WebSocketListener) -> @Sendable (Bool, MeetingProfile?) -> Void {
        { [weak self, weak listener] on, profile in
            let reported = self?.setMeeting(on: on, profile: profile ?? .meeting, connection: connection,
                                             reason: "voice") ?? 0
            if on, reported == 0, self?.duckMode(connection: connection) == true {
                self?.enqueuePrivacyClip(connection) { _ in { [weak self, weak listener] in
                    guard let self else { return }
                    var confirm = "unreported"
                    if privacyHeardOn(connection: connection) {
                        confirm = await confirmVoiceMute(AmbientStopConfirmation.privacyStatus, on: connection,
                                                         listener: listener)
                    }
                    emit("ambient_meeting_confirmed", connection: connection,
                         detail: "on=true profile=\((profile ?? .meeting).rawValue) confirm=\(confirm)")
                } }
            }
        }
    }

    /// Changes one host session (#735 meeting mode (rightyo#227)), atomically with media/privacy and registration.
    /// Same-profile entries and absent exits change nothing; a profile switch keeps the original start, rearms the
    /// timeout and reports one real on-change. `expected` admits only the current timeout's expiry.
    @discardableResult
    func setMeeting(on: Bool, profile: MeetingProfile = .meeting, connection: UUID, reason: String,
                    expected: UUID? = nil) -> Int {
        let reported = state.withLock { state -> Int? in
            if let expected, state.meeting[connection]?.token != expected { return 0 }
            if on, state.duck[connection] != nil { return nil }
            guard on else { return endMeeting(connection: connection, reason: reason, in: &state) }
            guard state.meeting[connection]?.profile != profile else { return 0 }
            let started = state.meeting[connection]?.started ?? Date(), token = UUID()
            state.meeting.removeValue(forKey: connection)?.timer.cancel()
            let timeout = configuration.meetingTimeout
            let timer = Task { [weak self] in
                try? await Task.sleep(for: .seconds(timeout))
                guard !Task.isCancelled else { return }
                self?.setMeeting(on: false, connection: connection, reason: "timeout", expected: token)
            }
            state.meeting[connection] = AmbientMeetingTimer(token: token, timer: timer, profile: profile,
                                                             started: started)
            // Install meeting first: leaving media writes true once, never a false/true pair.
            let reported = state.media[connection] != nil
                ? changeMedia(false, connection: connection, reason: "voice", in: &state)
                : reportModes(connection: connection, in: state)
            meetingChanged((true, profile), connection: connection, reason: reason, reported: reported,
                           listener: state.listener?.value)
            return reported
        }
        if let reported { return reported }
        emit("ambient_meeting", connection: connection,
             detail: "on=true profile=\(profile.rawValue) reason=\(reason) reported=0 refused=private")
        return 0
    }

    /// Ends a real session under the caller's lock (#735 meeting mode (rightyo#227)). Media entry supplies its own
    /// write; teardown needs none. Privacy supplies no extra clip. Removing first preserves the effective OR gate.
    @discardableResult
    func endMeeting(connection: UUID, reason: String, report: Bool = true, in state: inout State) -> Int {
        guard let meeting = state.meeting.removeValue(forKey: connection) else { return 0 }
        meeting.timer.cancel()
        let reported = report && reason != "connection" ? reportModes(connection: connection, in: state) : 0
        meetingChanged((false, meeting.profile), connection: connection, reason: reason, reported: reported,
                       listener: state.listener?.value)
        return reported
    }

    /// MM-C's seam and the owner's confirmation, queued under the state lock and run outside it, in change order.
    /// Only voice/timeout changes a child took play a clip. Missing clips log `no_clips` and never undo the mode.
    private func meetingChanged(_ mode: (on: Bool, profile: MeetingProfile), connection: UUID, reason: String,
                                reported: Int, listener: WebSocketListener?) {
        let (on, profile) = mode
        let hook = configuration.onMeetingChange
        meetingChanges.enqueue { [weak self, weak listener] in
            hook?(connection, on, profile, reason)
            guard let self else { return }
            emit("ambient_meeting", connection: connection,
                 detail: "on=\(on) profile=\(profile.rawValue) reason=\(reason) reported=\(reported)")
            guard reason == "voice" || reason == "timeout" else { return }
            var confirm = "unreported"
            if reported > 0 {
                let persona: String
                if reason == "timeout" {
                    persona = AmbientStopConfirmation.meetingEnded
                } else if profile == .rubberDuck {
                    persona = on ? AmbientStopConfirmation.rubberDuckOn : AmbientStopConfirmation.rubberDuckOff
                } else {
                    persona = on ? AmbientStopConfirmation.meetingOn : AmbientStopConfirmation.meetingOff
                }
                confirm = await confirmVoiceMute(persona, on: connection, listener: listener)
            }
            emit("ambient_meeting_confirmed", connection: connection,
                 detail: "on=\(on) profile=\(profile.rawValue) confirm=\(confirm)")
        }
    }
}
#endif
