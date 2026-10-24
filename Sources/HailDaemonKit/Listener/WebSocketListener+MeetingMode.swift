#if os(macOS)
public import Foundation

/// A connection's meeting state (#735 meeting mode (rightyo#227)): its guarded timeout, profile and original start.
/// #735 meeting mode restore (MM-E): `meetingID` is minted at first entry and kept through a profile switch, a park
/// and a restore; `expiresAt` is the absolute auto-end fixed when armed, so a restore re-arms only the time left.
/// `recording` is whether this meeting records here: true for an owner's new entry, kept through a profile switch or
/// a renewal, and decided on the meeting chain for a restore. `armed` is its arming order.
struct AmbientMeetingTimer {
    let token: UUID
    let timer: Task<Void, Never>
    let profile: MeetingProfile
    let started: Date
    let meetingID: UUID
    let expiresAt: Date
    var recording: Bool
    let armed: Int
}

/// One meeting change for MM-C's seam and the owner's clip (#735 meeting mode (rightyo#227)). `token` is an
/// on-change's timeout, which its clip checks again when it plays; `renewed` is a same-profile re-entry.
struct AmbientMeetingChange: Sendable {
    let on: Bool
    let profile: MeetingProfile
    var reason: String
    let reported: Int
    var token: UUID?
    var renewed = false
    let meetingID: UUID
    var recording: Bool

    /// The clip it plays, if any: a timeout says "ended", a restore "still on" (MM-E, no fallback); rubber duck falls
    /// back to the meeting clips until recorded. Media, privacy, teardown and moves play none.
    var persona: String? {
        switch reason {
        case "timeout": AmbientStopConfirmation.meetingEnded
        case "resumed", "resumed_unrecorded": AmbientStopConfirmation.meetingResumed
        case "voice" where profile == .rubberDuck:
            on ? AmbientStopConfirmation.rubberDuckOn : AmbientStopConfirmation.rubberDuckOff
        case "voice": on ? AmbientStopConfirmation.meetingOn : AmbientStopConfirmation.meetingOff
        default: nil
        }
    }

    func hooked(_ connection: UUID) -> MeetingChange {
        MeetingChange(connection: connection, on: on, profile: profile, reason: reason, meetingID: meetingID,
                      recording: on && recording)
    }
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
    /// An absent exit changes nothing. A same-profile entry rearms the timeout and replays the on clip as status, as
    /// media mode does, with no hook: nothing really changed (review round 1). A profile switch keeps the original
    /// start, rearms the timeout and reports one real on-change. A torn-down or private connection refuses entry.
    /// `expected` admits only the current timeout's expiry. Either rearm keeps the meeting's id and `recording` and
    /// fixes a fresh expiry; the owner's spoken word wins daemon-wide (MM-E): an off clears a parked meeting, an entry
    /// a parked media mode.
    @discardableResult
    func setMeeting(on: Bool, profile: MeetingProfile = .meeting, connection: UUID, reason: String,
                    expected: UUID? = nil) -> Int {
        let decided = state.withLock { state -> (reported: Int, refused: String?) in
            if let expected, state.meeting[connection]?.token != expected { return (0, nil) }
            if on, let refused = Self.entryRefusal(connection, in: state) { return (0, refused) }
            if reason == "voice" {
                discardParked(meeting: !on, media: on, reason: on ? "superseded" : "off", in: &state)
            }
            guard on else { return (endMeeting(connection: connection, reason: reason, in: &state), nil) }
            let current = state.meeting.removeValue(forKey: connection), token = UUID()
            current?.timer.cancel()
            let (timeout, meetingID, recording) = (configuration.meetingTimeout, current?.meetingID ?? UUID(),
                                                   current?.recording ?? true)
            state.meeting[connection] = AmbientMeetingTimer(
                token: token, timer: meetingTimeoutTask(connection: connection, token: token, after: timeout),
                profile: profile, started: current?.started ?? Date(), meetingID: meetingID,
                expiresAt: configuration.now().addingTimeInterval(timeout), recording: recording,
                armed: Self.arm(&state))
            // Install meeting first: leaving media writes true once, never a false/true pair.
            let reported = state.media[connection] != nil
                ? changeMedia(false, connection: connection, reason: "voice", in: &state)
                : reportModes(connection: connection, in: state)
            let change = AmbientMeetingChange(on: true, profile: profile, reason: reason, reported: reported,
                                              token: token, renewed: current?.profile == profile,
                                              meetingID: meetingID, recording: recording)
            meetingChanged(change, connection: connection, in: &state)
            return (reported, nil)
        }
        if let refused = decided.refused {
            emit("ambient_meeting", connection: connection,
                 detail: "on=true profile=\(profile.rawValue) reason=\(reason) reported=0 refused=\(refused)")
        }
        return decided.reported
    }

    /// Ends a real session under the caller's lock (#735 meeting mode (rightyo#227)). Media entry supplies its own
    /// write; teardown needs none. Privacy supplies no extra clip. Removing first preserves the effective OR gate.
    @discardableResult
    func endMeeting(connection: UUID, reason: String, report: Bool = true, in state: inout State) -> Int {
        guard let meeting = state.meeting.removeValue(forKey: connection) else { return 0 }
        meeting.timer.cancel()
        let reported = report && reason != "connection" ? reportModes(connection: connection, in: state) : 0
        meetingChanged(AmbientMeetingChange(on: false, profile: meeting.profile, reason: reason, reported: reported,
                                            meetingID: meeting.meetingID, recording: false),
                       connection: connection, in: &state)
        return reported
    }

    /// MM-C's seam and the owner's confirmation, both queued under the state lock in change order. The hook and its
    /// log run on the router-wide `meetingChanges`, which never awaits a clip, so one connection's slow clip cannot
    /// hold another's hook (review round 2). Only voice/timeout/restore changes a child took play a clip, on the
    /// connection's own clip chain beside its privacy clips; a renewal plays its clip with no hook. Missing clips log
    /// `no_clips` and never undo the mode. An on clip is checked again just before it plays (review round 1): one whose
    /// meeting has since ended, been replaced or gone private is `superseded`, never heard after "Privacy on". A
    /// restore (`resume`, MM-E) decides `recording` on `meetingChanges` before its hook (`decide`: a peer lookup, no
    /// clip); its "still on" clip takes the same clip chain and re-check.
    func meetingChanged(_ change: AmbientMeetingChange, connection: UUID, in state: inout State,
                        resume: MeetingResume? = nil) {
        let hook = change.renewed ? nil : configuration.onMeetingChange
        let listener = state.listener?.value
        meetingChanges.enqueue { [weak self, weak listener] in
            var change = change
            if let resume, let self {
                change = await decide(resume, for: change, connection: connection, listener: listener)
            }
            hook?(change.hooked(connection))
            let renewed = change.renewed ? " renewed=true" : ""
            self?.emit("ambient_meeting", connection: connection,
                       detail: "on=\(change.on) profile=\(change.profile.rawValue) reason=\(change.reason) "
                          + "reported=\(change.reported)\(renewed)")
        }
        guard let persona = change.persona else { return }
        Self.clipChain(connection, in: &state).enqueue { [weak self, weak listener] in
            guard let self else { return }
            var confirm = "unreported"
            if change.reported > 0, !meetingCurrent(change, connection: connection) {
                confirm = "superseded"
            } else if change.reported > 0 {
                confirm = await confirmVoiceMute(persona, on: connection, listener: listener)
            }
            emit("ambient_meeting_confirmed", connection: connection,
                 detail: "on=\(change.on) profile=\(change.profile.rawValue) confirm=\(confirm)")
        }
    }

    /// Whether an on-change is still the connection's meeting, under the lock that changes it: the same timeout, not
    /// private and not torn down. An off-change has nothing to supersede it.
    private func meetingCurrent(_ change: AmbientMeetingChange, connection: UUID) -> Bool {
        guard change.on else { return true }
        return state.withLock { state in
            state.meeting[connection]?.token == change.token && Self.entryRefusal(connection, in: state) == nil
        }
    }
}
#endif
