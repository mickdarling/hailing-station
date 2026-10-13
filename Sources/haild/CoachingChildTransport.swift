import Foundation
import HailCore
import HailDaemonKit

/// Foreground-only raw-PCM adapter. No HailHost, registry, action consumer, socket or network is constructed.
@MainActor final class CoachingChildTransport: ForegroundCoachingTransport {
    struct Configuration {
        let executable: URL, config: URL, profile: Data
        let listenerID: String
        let provenance: RightyoAudioProvenance
        let mockSuggestions: URL?
    }
    private let configuration: Configuration
    private let profile: Data
    private let hooks: ForegroundCoaching.ChildHooks
    private let activityFlags: () -> CoachingActivityFlags?
    private let activity = CoachingCaptureActivity()
    private let encoder = CoachingPCMEncoder()
    private var child: RightyoChildProcess?
    private var reader: Task<Void, Never>?
    private var lease: CoachingQualification?
    private var session: UUID?
    private var closed = false, started = false
    private var sequence = 0
    private var finals: Set<String> = []
    var finalCount: Int { finals.count }
    private(set) var adviceCount = 0

    init(_ configuration: Configuration, hooks: ForegroundCoaching.ChildHooks,
         activityFlags: @escaping () -> CoachingActivityFlags?) throws {
        self.configuration = configuration; self.hooks = hooks; self.activityFlags = activityFlags
        profile = try CoachingChildCodec.profile(configuration.profile, listenerID: configuration.listenerID)
    }
    isolated deinit {
        reader?.cancel()
        if let child { child.abandonCoachingInput(); Task { await child.stop() } }
    }

    func send(_ control: ForegroundCoachingControl) -> Bool {
        guard !closed else { return false }
        do {
            switch control {
            case .enable(let session, let destination, let listener):
                guard child == nil, self.session == nil, listener == configuration.listenerID else { return false }
                let child = try RightyoChildProcess(executable: configuration.executable, config: configuration.config,
                    session: session.uuidString.lowercased(), provenance: configuration.provenance,
                    coaching: RightyoCoachingLaunch(mockSuggestions: configuration.mockSuggestions))
                self.child = child; self.session = session
                read(child)
                let enable = try CoachingChildCodec.control("enable", session: session, fields: [
                    "destination_id": destination.uuidString.lowercased(), "listener_id": listener,
                    "participant_awareness": true])
                return child.sendCoachingControl(profile, validUntil: .now.advanced(by: .seconds(1)))
                    && child.sendCoachingControl(enable, validUntil: .now.advanced(by: .seconds(1)))
            case .qualify(let fresh):
                guard let child, session == fresh.sessionID, child.counters.droppedChunks == 0,
                      lease == nil || (lease?.generation == fresh.generation
                          && lease?.destinationID == fresh.destinationID)
                else { return false }
                let milliseconds = CoachingChildCodec.milliseconds(until: fresh.expiresAt, at: .now)
                guard milliseconds > 0 else { return false }
                let data = try CoachingChildCodec.control("qualify", session: fresh.sessionID, fields: [
                    "destination_id": fresh.destinationID.uuidString.lowercased(),
                    "generation_id": fresh.generation.uuidString.lowercased(),
                    "qualification_id": fresh.qualificationID.uuidString.lowercased(), "valid_for_ms": milliseconds])
                guard child.sendCoachingControl(data, validUntil: fresh.expiresAt) else { return false }
                lease = fresh; return true
            case .disable(let session):
                guard self.session == session, let child else { return false }
                lease = nil
                return child.sendCoachingControl(try CoachingChildCodec.control("disable", session: session),
                                                 validUntil: .now.advanced(by: .milliseconds(250)))
            }
        } catch { close(); return false }
    }

    func write(_ buffer: AudioCaptureBuffer) -> Bool {
        guard !closed, let child, let lease, ContinuousClock.now < lease.expiresAt,
              child.counters.droppedChunks == 0 else { return false }
        do {
            let data = try encoder.encode(buffer)
            activity.observe(data)
            return !closed && self.lease == lease && ContinuousClock.now < lease.expiresAt
                && (data.isEmpty || child.write(data)) && child.counters.droppedChunks == 0
        } catch { return false }
    }

    func close() {
        closed = true; lease = nil; reader?.cancel(); child?.abandonCoachingInput()
    }
    func stop() async {
        close()
        if let child { await child.stop() }
        await reader?.value
        reader = nil; child = nil
    }

    private func read(_ child: RightyoChildProcess) {
        reader = Task { [weak self] in
            do {
                for try await data in child.lines {
                    guard !Task.isCancelled else { break }
                    try self?.consume(data)
                }
            } catch { /* Content-free retirement; child stderr and transcript never logged. */ }
            self?.ended()
        }
    }

    private func ended() {
        guard !closed else { return }
        close(); hooks.ended()
    }

    private func consume(_ data: Data) throws {
        guard !closed, data.count <= 32_768,
              let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              object["schema_version"] as? Int == 1, let type = object["type"] as? String else {
            throw CoachingChildError.invalidOutput
        }
        if type == "coaching_advice" { guard started else { throw CoachingChildError.invalidOutput }
            adviceCount += 1
            hooks.advice(data); return }
        if type == "coaching_state" {
            if ["suspended", "disabled"].contains(object["state"] as? String ?? ""),
               object["reason"] as? String != "initial" { ended() }
            return // Advisory only; never a grant or a lease renewal.
        }
        guard object["session_id"] as? String == session?.uuidString.lowercased(),
              let next = object["sequence"] as? Int, next == sequence + 1 else {
            throw CoachingChildError.invalidOutput
        }
        _ = try RightyoInputEvent.decode(data) // Existing ordinary typed event envelope; no action consumer.
        sequence = next
        if type == "session" {
            if object["phase"] as? String == "started", !started { started = true; return }
            if ["stopped", "cancelled", "error"].contains(object["phase"] as? String ?? ""), started {
                ended(); return
            }
        }
        try final(object, type: type)
    }

    private func final(_ object: [String: Any], type: String) throws {
        guard type == "transcript", started, finals.count < 1_000,
              let session,
              let lease, ContinuousClock.now < lease.expiresAt else { throw CoachingChildError.invalidOutput }
        let utterance = try CoachingChildCodec.finalID(object, session: session.uuidString.lowercased(),
                                                       provenance: configuration.provenance)
        guard finals.insert(utterance).inserted else { throw CoachingChildError.invalidOutput }
        let received = ContinuousClock.now
        guard let flags = activityFlags(), let measurement = activity.measure(flags) else { return }
        // Missing trusted evidence holds; never infer from words. Callbacks may have retired this lease.
        let activity = try CoachingChildCodec.activity(measurement, utterance: utterance, lease: lease)
        guard !closed, self.lease == lease, ContinuousClock.now < lease.expiresAt,
              ContinuousClock.now - received < .seconds(2),
              child?.sendCoachingControl(activity, validUntil: min(lease.expiresAt, received.advanced(by: .seconds(2))))
                == true else { throw CoachingChildError.invalidControl }
    }
}
