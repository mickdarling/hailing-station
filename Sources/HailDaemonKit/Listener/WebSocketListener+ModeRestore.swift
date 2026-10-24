#if os(macOS)
import Foundation

/// A meeting a dropped (or still live, stale) connection held (#735 meeting mode restore (MM-E)): its profile, stable
/// id, original start and expiry, where it was, whether it recorded there, and its arming order.
struct ParkedMeeting: Sendable {
    let profile: MeetingProfile
    let meetingID: UUID
    let started: Date
    let expiresAt: Date
    let connection: UUID
    let recording: Bool
    let armed: Int
}

/// A media mode (#551) likewise (MM-E): its original expiry, where it was, and its arming order.
struct ParkedMedia: Sendable {
    let expiresAt: Date
    let connection: UUID
    let armed: Int
}

/// Reserved for privacy restore (#735 S-7a); never set yet.
struct ParkedPrivacy: Sendable {}

/// The mode parked daemon-wide (MM-E), in RAM only, so a haild restart restores nothing. At most one kind: the latest
/// owner command wins. There is no authenticated device identity (connection ids are fresh and Hello names are
/// claims), so any connection's next start restores it, and only ever quieter: the gate, never a recording on
/// another device's claims. `device` is the dropped connection's Hello claims (nil when unknown, never a match).
struct ParkedModes: Sendable {
    var meeting: ParkedMeeting?
    var media: ParkedMedia?
    var privacy: ParkedPrivacy?
    var device: AmbientPeerDevice?
    var parkedAt: Date
    var armed: Int { meeting?.armed ?? media?.armed ?? Int.min }
    var expiresAt: Date { meeting?.expiresAt ?? media?.expiresAt ?? .distantPast }
    var mode: String { meeting != nil ? "meeting" : "media" }
}

/// Where a restored mode came from (MM-E): a park, with its device's claims, or a live connection still holding it
/// (haild has no keepalive, so a dropped phone's old connection can outlive its reconnect).
enum RestoreSource: Sendable {
    case park(AmbientPeerDevice?)
    case live
    var token: String { if case .park = self { "park" } else { "live" } }

    /// The claims to match: the park's, or the live holder's own, read now (nil once it is gone: no match).
    func device(of holder: UUID, listener: WebSocketListener?) async -> AmbientPeerDevice? {
        if case .park(let device) = self { return device }
        return await listener?.ambientPeerDevice(connection: holder)
    }
}

/// A meeting restore's recording decision, made on the meeting chain (`meetingChanged`), outside the lock.
struct MeetingResume: Sendable {
    let source: RestoreSource
    let from: UUID
    /// Whether it recorded where it was: a restore records only if it did and the claims match.
    let recording: Bool
    /// The restored arming, on which the decision is stored while it is still the current one.
    let token: UUID
    let remaining: Int
}

/// #735 meeting mode restore (MM-E): a meeting or media mode left on by a dropped connection is parked on teardown, or
/// still held by a stale one, and carried to the next ambient start on any connection, before its original expiry.
/// Privacy always wins: a private connection parks and holds nothing, a private start takes nothing, a privacy entry
/// anywhere discards the park, and the owner's own off (or the other mode's entry) clears it. Logs ids, tokens,
/// counts and booleans only, never words or device names.
extension AmbientRightyoRouter {
    /// Parks `connection`'s mode under the caller's lock (`stop(connection:device:)`), before teardown removes it. The
    /// original expiry is kept, so repeated drops never extend a mode; only the latest-armed of two parks is kept.
    func park(connection: UUID, device: AmbientPeerDevice?, in state: inout State) {
        guard state.duck[connection] == nil else { return }
        let now = configuration.now()
        var mine = ParkedModes(device: device, parkedAt: now)
        if let meeting = state.meeting[connection] {
            mine.meeting = ParkedMeeting(profile: meeting.profile, meetingID: meeting.meetingID,
                                         started: meeting.started, expiresAt: meeting.expiresAt,
                                         connection: connection, recording: meeting.recording, armed: meeting.armed)
            logLater("ambient_meeting_parked", connection: connection,
                     detail: "remaining=\(Self.seconds(meeting.expiresAt, now)) meeting=\(meeting.meetingID)")
        } else if let media = state.media[connection] {
            mine.media = ParkedMedia(expiresAt: media.expiresAt, connection: connection, armed: media.armed)
            logLater("ambient_media_parked", connection: connection,
                     detail: "remaining=\(Self.seconds(media.expiresAt, now))")
        } else {
            return
        }
        if let old = state.parked, old.armed > mine.armed {
            return logLater("ambient_park_discarded", detail: "reason=superseded mode=\(mine.mode)")
        }
        if let old = state.parked { logLater("ambient_park_discarded", detail: "reason=superseded mode=\(old.mode)") }
        state.parked = mine
    }

    /// Carries the latest-armed mode, parked or still held by another (stale) connection, onto `connection`'s new
    /// stream, under the lock `start` registers its first run under, right after `register`: the new child's first mode
    /// write is the gate, so it never runs ungated while a mode is on daemon-wide. Only into a connection in no mode,
    /// and only for its current, open stream: one torn down or superseded mid-start takes nothing, but its child still
    /// gets the gate while any mode is held or parked (review round 2), with no hook and no clip. A private start ends
    /// every other holder's mode and the park, as a privacy entry does.
    func carryModes(to connection: UUID, stream: UUID, pipeline: RightyoAmbientPipeline, in state: inout State) {
        guard state.meeting[connection] == nil, state.media[connection] == nil else { return }
        guard state.latest[connection] == stream, !state.closed.contains(connection) else {
            if state.parked != nil || !state.meeting.isEmpty || !state.media.isEmpty { pipeline.reportMedia(true) }
            return
        }
        if state.duck[connection] != nil { return endEveryMode(reason: "privacy", except: connection, in: &state) }
        let now = configuration.now()
        if let parked = state.parked, parked.expiresAt <= now {
            discardParked(meeting: true, media: true, reason: "expired", in: &state)
        }
        let holders = Self.holders(except: connection, at: now, in: state)
        let top = holders.first.flatMap { $0.armed > state.parked?.armed ?? Int.min ? $0.connection : nil }
        if top != nil { discardParked(meeting: true, media: true, reason: "superseded", in: &state) }
        let parked = state.parked
        state.parked = nil
        holders.filter { $0.connection != top }.forEach {
            endHeld($0.connection, reason: "superseded", in: &state)
        }
        if let top, let meeting = state.meeting[top] {
            endHeld(top, reason: "moved", to: connection, in: &state)
            restore(ParkedMeeting(profile: meeting.profile, meetingID: meeting.meetingID, started: meeting.started,
                                  expiresAt: meeting.expiresAt, connection: top, recording: meeting.recording,
                                  armed: meeting.armed), source: .live, connection: connection, now: now, in: &state)
        } else if let top, let media = state.media[top] {
            endHeld(top, reason: "moved", to: connection, in: &state)
            restore(ParkedMedia(expiresAt: media.expiresAt, connection: top, armed: media.armed),
                    source: .live, connection: connection, now: now, in: &state)
        } else if let meeting = parked?.meeting {
            restore(meeting, source: .park(parked?.device), connection: connection, now: now, in: &state)
        } else if let media = parked?.media {
            restore(media, source: .park(parked?.device), connection: connection, now: now, in: &state)
        }
    }

    /// Other connections holding a mode not yet expired, latest-armed first. A private connection holds none.
    private static func holders(except connection: UUID, at now: Date,
                                in state: State) -> [(connection: UUID, armed: Int)] {
        let meetings = state.meeting.filter { $0.value.expiresAt > now }.map { ($0.key, $0.value.armed) }
        let media = state.media.filter { $0.value.expiresAt > now }.map { ($0.key, $0.value.armed) }
        return (meetings + media).filter { $0.0 != connection && state.duck[$0.0] == nil }
            .sorted { $0.1 > $1.1 }.map { (connection: $0.0, armed: $0.1) }
    }

    /// Re-arms a meeting with the time left to its original expiry, same profile and id, unrecorded until the meeting
    /// chain decides (`decide`): recorded only if it recorded where it was and the claims match. Its clip goes through
    /// the meeting's own clip path and re-check, as an owner's entry does.
    private func restore(_ meeting: ParkedMeeting, source: RestoreSource, connection: UUID, now: Date,
                         in state: inout State) {
        let token = UUID(), remaining = meeting.expiresAt.timeIntervalSince(now)
        state.meeting[connection] = AmbientMeetingTimer(
            token: token, timer: meetingTimeoutTask(connection: connection, token: token, after: remaining),
            profile: meeting.profile, started: meeting.started, meetingID: meeting.meetingID,
            expiresAt: meeting.expiresAt, recording: false, armed: meeting.armed)
        let reported = reportModes(connection: connection, in: state)
        meetingChanged(AmbientMeetingChange(on: true, profile: meeting.profile, reason: "resumed_unrecorded",
                                            reported: reported, token: token, meetingID: meeting.meetingID,
                                            recording: false),
                       connection: connection, in: &state,
                       resume: MeetingResume(source: source, from: meeting.connection, recording: meeting.recording,
                                             token: token, remaining: Self.seconds(meeting.expiresAt, now)))
    }

    /// A restore's recording decision (MM-E) on the meeting chain, outside the lock: the new connection's claims must
    /// match its source's, and the meeting must have recorded there; once unrecorded, a meeting never records again.
    /// Stored while that arming is current; logged as ids and booleans, never names.
    func decide(_ resume: MeetingResume, for change: AmbientMeetingChange, connection: UUID,
                listener: WebSocketListener?) async -> AmbientMeetingChange {
        let here = await listener?.ambientPeerDevice(connection: connection)
        let match = AmbientPeerDevice.matches(here, await resume.source.device(of: resume.from, listener: listener))
        let recording = match && resume.recording
        state.withLock { state in
            guard state.meeting[connection]?.token == resume.token else { return }
            state.meeting[connection]?.recording = recording
        }
        emit("meeting_restored", connection: connection,
             detail: "source=\(resume.source.token) from=\(resume.from) to=\(connection) meeting=\(change.meetingID) "
                 + "recording=\(recording) device_match=\(match) profile=\(change.profile.rawValue) "
                 + "remaining=\(resume.remaining) reported=\(change.reported)")
        var decided = change
        (decided.reason, decided.recording) = (recording ? "resumed" : "resumed_unrecorded", recording)
        return decided
    }

    /// Clears the parked mode named, under the caller's lock: the owner's off (`off`), the other mode's entry
    /// (`superseded`), its expiry (`expired`) or a privacy entry (`privacy`).
    func discardParked(meeting: Bool, media: Bool, reason: String, in state: inout State) {
        guard let parked = state.parked, meeting && parked.meeting != nil || media && parked.media != nil else {
            return
        }
        state.parked = nil
        logLater("ambient_park_discarded", detail: "reason=\(reason) mode=\(parked.mode)")
    }
}
#endif
