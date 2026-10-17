public import Foundation
public import HailProtocol
#if os(iOS)
import AVFAudio
#endif
#if os(macOS)
import AVFAudio
import CoreAudio
#endif

@MainActor protocol CoachingOutputMonitoring: AnyObject {
    var onInvalidated: (() -> Void)? { get set }
    func arm() throws
    func observe() -> CoachingOutputObservation
    func disarm()
    func retains(_ token: UUID) -> Bool
}

extension CoachingOutputMonitor: CoachingOutputMonitoring {}

public enum CoachingPlaybackObservation: Sendable, Equatable { case unavailable, idle, pending }

/// Unactivated production composition, separate from ordinary ambient capture and reply masking.
/// iOS uses its actual current output, a dedicated raw capture engine and a non-activating player on that engine.
/// iOS denies Bluetooth/AirPods. Native Mac uses separately verified fixed HAL bindings; no UI/daemon enables it.
@MainActor
public final class ApplePrivateCoaching {
    private let monitor: any CoachingOutputMonitoring
    private let session: PrivateCoachingSession
    private let consumer: CoachingAdviceConsumer
    private let renderer: CoachingEngineRenderer?
    private var lifecycleRevision = UUID()

    #if os(iOS)
    public convenience init(listenerID: String, hooks: PrivateCoachingSession.Hooks) throws {
        let engine = AVAudioEngine()
        let monitor = CoachingOutputMonitor()
        let player = CoachingEngineRenderer(operations: .live(engine: engine), observe: { monitor.observe() })
        try self.init(capture: AVAudioEngineCapture(engine: engine), player: player,
                      monitor: monitor, listenerID: listenerID, hooks: hooks)
    }
    #endif

    init(capture: any AudioCapturing, player: any CoachingAudioPlaying, monitor: any CoachingOutputMonitoring,
         listenerID: String, hooks: PrivateCoachingSession.Hooks, clock: CoachingClock = .init()) throws {
        self.monitor = monitor
        renderer = player as? CoachingEngineRenderer
        session = PrivateCoachingSession(capture: capture, player: player,
                                        observeOutput: { monitor.observe() }, hooks: hooks, clock: clock)
        consumer = try CoachingAdviceConsumer(session: session, listenerID: listenerID)
        monitor.onInvalidated = { [weak consumer] in consumer?.invalidate() }
    }

    isolated deinit { monitor.disarm(); consumer.stop() }

    /// Explicit opt-in and awareness precede capture. Unqualified output fails before microphone start.
    @discardableResult
    public func begin(sessionID: UUID, destinationID: UUID, consentConfirmed: Bool) throws -> CoachingQualification {
        guard !session.transitioning else { throw CoachingSafetyError.transitionInProgress }
        let revision = UUID()
        lifecycleRevision = revision
        retire(revision, invalidating: false)
        guard lifecycleRevision == revision else { throw CoachingSafetyError.staleQualification }
        guard consentConfirmed else { throw CoachingSafetyError.consentRequired }
        var startedLease: CoachingQualification?
        do {
            try monitor.arm()
            guard lifecycleRevision == revision else { throw CoachingSafetyError.staleQualification }
            let lease = try session.begin(sessionID: sessionID, destinationID: destinationID, consentConfirmed: true)
            startedLease = lease
            try consumer.register(lease)
            guard lifecycleRevision == revision else { throw CoachingSafetyError.staleQualification }
            return lease
        } catch {
            if lifecycleRevision == revision, session.qualification == startedLease { stop() }
            throw error
        }
    }

    @discardableResult
    public func renew(_ lease: CoachingQualification) throws -> CoachingQualification {
        let revision = lifecycleRevision
        var ownedLease = lease
        do {
            let fresh = try session.renew(lease)
            ownedLease = fresh
            try consumer.register(fresh)
            return fresh
        } catch {
            // Observation/registration can publish a newer lease within this same generation.
            if lifecycleRevision == revision, session.qualification == nil || session.qualification == ownedLease {
                stop()
            }
            throw error
        }
    }

    public func admit(_ data: Data) throws -> AdmittedCoachingAdvice { try consumer.admit(data) }
    public func schedule(_ payload: AudioPayload, for advice: AdmittedCoachingAdvice) throws {
        try authorized(advice) { try consumer.schedule(payload, for: advice) }
    }
    public func resume(_ advice: AdmittedCoachingAdvice) throws {
        try authorized(advice) { try consumer.resume(advice) }
    }

    /// Conservative trusted activity evidence: queued/paused/muted PCM counts as playback until completed.
    /// Unavailable is unknown/off, never idle. Observes the owned queue; grants no qualification or route.
    public func privatePlaybackObservation() -> CoachingPlaybackObservation {
        guard !session.transitioning, let live = session.current() else { return .unavailable }
        let now = session.clock.now()
        guard !session.transitioning, session.qualification == live, session.hasLiveDeadlines(live, at: now),
              monitor.retains(live.outputID) else { return .unavailable }
        return session.pendingPlayback.isEmpty ? .idle : .pending
    }
    public func setMuted(_ muted: Bool, for advice: AdmittedCoachingAdvice) throws {
        try authorized(advice) { try consumer.setMuted(muted, for: advice) }
    }

    private func authorized(_ advice: AdmittedCoachingAdvice, perform: () throws -> Void) throws {
        guard let renderer else { try perform(); return } // Injected trusted players retain the core contract.
        try renderer.withAuthorization({ [session] in (try? session.validate(advice.ticket)) != nil },
                                       perform: perform, owns: { [session] in
            session.qualification?.generation == advice.ticket.qualification.generation
        }, finalGate: { [weak self] in self?.effectsAllowed(advice.ticket) == true },
        onFailure: { [weak self, session] in
            guard session.qualification?.generation == advice.ticket.qualification.generation else { return }
            self?.invalidate()
        })
    }

    /// Final authority after renderer readiness. No callback-capable route observation follows this check.
    private func effectsAllowed(_ ticket: CoachingAdviceTicket) -> Bool {
        guard !session.transitioning, let live = session.qualification,
              session.sameScope(ticket.qualification, live) else { return false }
        let now = session.clock.now()
        return !session.transitioning && session.qualification == live && session.hasLiveDeadlines(live, at: now)
            && now < ticket.qualification.expiresAt && monitor.retains(live.outputID)
    }

    /// Owner must call on connection/permission/participant-awareness loss, before any route rebuilding.
    public func invalidate() {
        let revision = UUID(); lifecycleRevision = revision
        retire(revision, invalidating: true)
    }
    public func stop() {
        let revision = UUID(); lifecycleRevision = revision
        retire(revision, invalidating: false)
    }
    private func retire(_ revision: UUID, invalidating: Bool) {
        monitor.disarm()
        guard lifecycleRevision == revision else { return }
        if invalidating { consumer.invalidate() } else { consumer.stop() }
    }
}

#if os(macOS)
extension ApplePrivateCoaching {
    /// Local operator IDs, not a remote requested route. No IO starts until consent-confirmed begin.
    /// AirPods are conditional on independent OS headphone terminal evidence plus actual fixed HAL readback.
    public convenience init(privateOutputDeviceID: UInt32, roomMicrophoneDeviceID: UInt32,
                            listenerID: String, hooks: PrivateCoachingSession.Hooks) throws {
        guard privateOutputDeviceID != kAudioObjectUnknown, roomMicrophoneDeviceID != kAudioObjectUnknown,
              privateOutputDeviceID != roomMicrophoneDeviceID else { throw CoachingSafetyError.unsafeOutput }
        let outputEngine = AVAudioEngine()
        let inputEngine = AVAudioEngine()
        guard let evidence = MacCoachingDeviceEvidence.read(privateOutputDeviceID) else {
            throw CoachingSafetyError.unsafeOutput
        }
        let binding = try Self.bindPrivateOutput(evidence,
            read: { MacCoachingDeviceEvidence.read(privateOutputDeviceID) },
            operations: .live(engine: outputEngine))
        let owner = try MacCoachingAudioOwner.live(inputEngine: inputEngine, outputEngine: outputEngine,
                                                  microphoneID: roomMicrophoneDeviceID, outputBinding: binding)
        let monitor = try MacCoachingOutputMonitor.live(owner: owner, output: evidence)
        let player = CoachingEngineRenderer(operations: .live(engine: outputEngine), observe: { monitor.observe() })
        try self.init(capture: owner, player: player, monitor: monitor, listenerID: listenerID, hooks: hooks)
    }

    static func bindPrivateOutput(_ evidence: MacCoachingDeviceEvidence,
                                  read: @escaping () -> MacCoachingDeviceEvidence?,
                                  operations: MacCoachingBindingOperations) throws -> MacCoachingOutputBinding {
        try MacCoachingOutputBinding(deviceID: evidence.deviceID, read: {
            guard read() == evidence else { return nil }
            return evidence // The exact listener snapshot is also the binding's permanent authority.
        }, operations: operations)
    }
}
#endif
