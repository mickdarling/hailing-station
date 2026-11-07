#if os(macOS)
public import Foundation

/// A connection's meeting state (#735 meeting mode (rightyo#227)): its guarded timeout, profile and original start.
/// #735 meeting mode restore (MM-E): `meetingID` is minted at first entry and kept through a profile switch, a park
/// and a restore; `expiresAt` is the absolute auto-end fixed when armed, so a restore re-arms only the time left.
/// `recording` is whether this meeting records here: true for an owner's new entry, kept through a profile switch or
/// a renewal, and decided on the meeting chain for a restore. Once false it stays false for the rest of that meeting,
/// even back on the device that recorded it (conservative, review round 2). `armed` is its arming order; `resume` the
/// restore or move arming whose decision this awaits (review round 4), kept by renewals and switches, nil otherwise.
struct AmbientMeetingTimer {
    let token: UUID
    let timer: Task<Void, Never>
    let profile: MeetingProfile
    let started: Date
    let meetingID: UUID
    let expiresAt: Date
    var recording: Bool
    let armed: Int
    var resume: UUID?
    /// The stream that armed this meeting also owns its eventual timeout confirmation.
    var target: String?
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

    /// One swappable child write (#735 meeting mode (rightyo#227)): the media gate, as before for every child while
    /// either mode is on, and RightyO's meeting control beside it for a child that advertised it (MM-D).
    @discardableResult func reportModes(to child: RightyoAmbientPipeline, connection: UUID, in state: State) -> Bool {
        child.reportModes(media: state.media[connection] != nil, meeting: state.meeting[connection] != nil)
    }
    /// Tells every child under the caller's lock, as media mode does; a write never blocks.
    func reportModes(connection: UUID, in state: State) -> Int {
        state.runs.values.filter {
            $0.connection == connection && reportModes(to: $0.pipeline, connection: connection, in: state)
        }.count
    }
    /// The owner's meeting command, held back like media mode (#735 meeting mode (rightyo#227)). A private entry
    /// hears only the privacy status, and only after privacy was announced, decided on its own clip chain.
    func voiceMeeting(on connection: UUID, target: String,
                      listener: WebSocketListener) -> @Sendable (Bool, MeetingProfile?) -> Void {
        return { [weak self, weak listener] on, profile in
            let reported = self?.setMeeting(on: on, profile: profile ?? .meeting, connection: connection,
                                             reason: "voice", target: target) ?? 0
            if on, reported == 0, self?.duckMode(connection: connection) == true {
                self?.enqueuePrivacyClip(connection) { _ in { [weak self, weak listener] in
                    guard let self else { return }
                    var confirm = "unreported"
                    if privacyHeardOn(connection: connection) {
                        confirm = await confirmVoiceMute(AmbientStopConfirmation.privacyStatus, on: connection,
                                                         target: target, listener: listener)
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
                    expected: UUID? = nil, target: String? = nil) -> Int {
        let decided = state.withLock { state -> (reported: Int, refused: String?) in
            if let expected, state.meeting[connection]?.token != expected { return (0, nil) }
            if on, let refused = Self.entryRefusal(connection, in: state) { return (0, refused) }
            if reason == "voice" {
                discardParked(meeting: !on, media: on, reason: on ? "superseded" : "off", in: &state)
            }
            let target = target ?? (reason == "timeout" ? state.meeting[connection]?.target
                                    : streamTarget(on: connection, in: state))
            guard on else {
                return (endMeeting(connection: connection, reason: reason, target: target, in: &state), nil)
            }
            let current = state.meeting.removeValue(forKey: connection), token = UUID()
            current?.timer.cancel()
            let (timeout, meetingID, recording) = (configuration.meetingTimeout, current?.meetingID ?? UUID(),
                                                   current?.recording ?? true)
            state.meeting[connection] = AmbientMeetingTimer(
                token: token, timer: meetingTimeoutTask(connection: connection, token: token, after: timeout),
                profile: profile, started: current?.started ?? Date(), meetingID: meetingID,
                expiresAt: configuration.now().addingTimeInterval(timeout), recording: recording,
                armed: Self.arm(&state), resume: current?.resume)
            // Install meeting first: leaving media writes true once, never a false/true pair.
            let reported = state.media[connection] != nil
                ? changeMedia(false, connection: connection, reason: "voice", in: &state).reported
                : reportModes(connection: connection, in: state)
            let change = AmbientMeetingChange(on: true, profile: profile, reason: reason, reported: reported,
                                              token: token, renewed: current?.profile == profile,
                                              meetingID: meetingID, recording: recording)
            meetingChanged(change, connection: connection, target: target, in: &state)
            return (reported, nil)
        }
        if let refused = decided.refused {
            emit("ambient_meeting", connection: connection,
                 detail: "on=true profile=\(profile.rawValue) reason=\(reason) reported=0 refused=\(refused)")
        }
        return decided.reported
    }
    /// Ends under the caller's lock. Removing first preserves the OR gate; privacy/teardown add no clip.
    @discardableResult
    func endMeeting(connection: UUID, reason: String, report: Bool = true, target: String? = nil,
                    in state: inout State) -> Int {
        guard let meeting = state.meeting.removeValue(forKey: connection) else { return 0 }
        meeting.timer.cancel()
        let reported = report && reason != "connection" ? reportModes(connection: connection, in: state) : 0
        meetingChanged(AmbientMeetingChange(on: false, profile: meeting.profile, reason: reason, reported: reported,
                                            meetingID: meeting.meetingID, recording: false),
                       connection: connection, target: target ?? meeting.target, in: &state)
        return reported
    }

    /// Queues MM-C on `meetingChanges` (never awaiting clips), and voice/timeout/restore confirmations on the
    /// connection's privacy chain, under the state lock in change order. Renewals have no hook. Missing clips
    /// never undo the mode. On clips recheck the meeting before playback; superseded/private meetings stay silent.
    /// A restore decides `recording` before its hook; its "still on" clip uses the same chain and recheck.
    func meetingChanged(_ change: AmbientMeetingChange, connection: UUID, target: String? = nil, in state: inout State,
                        resume: MeetingResume? = nil) {
        let hook = change.renewed ? nil : configuration.onMeetingChange
        let listener = state.listener?.value
        let held = state.runs.values.contains { $0.connection == connection && $0.pipeline.meetingHeld(change.on) }
        meetingChanges.enqueue { [weak self, weak listener] in
            var change = change
            if let resume, let self {
                change = await decide(resume, for: change, connection: connection, listener: listener)
            } else if change.on, let self { change.recording = recorded(change, connection: connection) }
            hook?(change.hooked(connection))
            let renewed = change.renewed ? " renewed=true" : ""
            self?.emit("ambient_meeting", connection: connection,
                       detail: "on=\(change.on) profile=\(change.profile.rawValue) reason=\(change.reason) "
                          + "reported=\(change.reported)\(renewed)")
            self?.emit("ambient_meeting_control", connection: connection, detail: "meeting_control=\(held)")
        }
        // Store once, even for a persona-less restore. A timeout without a retained target stays silent.
        let target = target ?? (change.reason == "timeout" ? nil : streamTarget(on: connection, in: state))
        if change.on, state.meeting[connection]?.token == change.token { state.meeting[connection]?.target = target }
        guard let persona = change.persona, let target else { return }
        Self.clipChain(connection, in: &state).enqueue { [weak self, weak listener] in
            guard let self else { return }
            var confirm = "unreported"
            if change.reported > 0, !meetingCurrent(change, connection: connection) {
                confirm = "superseded"
            } else if change.reported > 0 {
                confirm = await confirmVoiceMute(persona, on: connection, target: target, listener: listener)
            }
            emit("ambient_meeting_confirmed", connection: connection,
                 detail: "on=\(change.on) profile=\(change.profile.rawValue) confirm=\(confirm)")
        }
    }
    /// Rechecks the on-change's timeout, privacy and teardown; an off-change cannot be superseded.
    private func meetingCurrent(_ change: AmbientMeetingChange, connection: UUID) -> Bool {
        guard change.on else { return true }
        return state.withLock { state in
            state.meeting[connection]?.token == change.token && Self.entryRefusal(connection, in: state) == nil
        }
    }
}
#endif
