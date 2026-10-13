public import Foundation
public import HailProtocol
#if os(iOS)
import AVFAudio
#endif

/// Unactivated production composition, separate from ordinary ambient capture and reply masking.
/// iOS uses its actual current output, a dedicated raw capture engine and a non-activating player on that engine.
/// Bluetooth/AirPods and native macOS are unsupported; no UI/daemon enables this object by default.
@MainActor
public final class ApplePrivateCoaching {
    private let monitor: CoachingOutputMonitor
    private let session: PrivateCoachingSession
    private let consumer: CoachingAdviceConsumer
    private let renderer: CoachingEngineRenderer?

    #if os(iOS)
    public convenience init(listenerID: String, hooks: PrivateCoachingSession.Hooks) throws {
        let engine = AVAudioEngine()
        let monitor = CoachingOutputMonitor()
        let player = CoachingEngineRenderer(operations: .live(engine: engine), observe: { monitor.observe() })
        try self.init(capture: AVAudioEngineCapture(engine: engine), player: player,
                      monitor: monitor, listenerID: listenerID, hooks: hooks)
    }
    #endif

    init(capture: any AudioCapturing, player: any CoachingAudioPlaying, monitor: CoachingOutputMonitor,
         listenerID: String, hooks: PrivateCoachingSession.Hooks, clock: CoachingClock = .init()) throws {
        self.monitor = monitor
        renderer = player as? CoachingEngineRenderer
        session = PrivateCoachingSession(capture: capture, player: player,
                                        observeOutput: { monitor.observe() }, hooks: hooks, clock: clock)
        consumer = try CoachingAdviceConsumer(session: session, listenerID: listenerID)
        monitor.onInvalidated = { [weak consumer] in consumer?.invalidate() }
    }

    isolated deinit { monitor.disarm(); consumer.stop() }

    /// Explicit opt-in and awareness precede capture. Unknown/Bluetooth output fails before microphone start.
    @discardableResult
    public func begin(sessionID: UUID, destinationID: UUID, consentConfirmed: Bool) throws -> CoachingQualification {
        stop()
        guard consentConfirmed else { throw CoachingSafetyError.consentRequired }
        do {
            try monitor.arm()
            let lease = try session.begin(sessionID: sessionID, destinationID: destinationID, consentConfirmed: true)
            try consumer.register(lease)
            return lease
        } catch { stop(); throw error }
    }

    @discardableResult
    public func renew(_ lease: CoachingQualification) throws -> CoachingQualification {
        do {
            let fresh = try session.renew(lease)
            try consumer.register(fresh)
            return fresh
        } catch { stop(); throw error }
    }

    public func admit(_ data: Data) throws -> AdmittedCoachingAdvice { try consumer.admit(data) }
    public func schedule(_ payload: AudioPayload, for advice: AdmittedCoachingAdvice) throws {
        try authorized(advice) { try consumer.schedule(payload, for: advice) }
    }
    public func resume(_ advice: AdmittedCoachingAdvice) throws {
        try authorized(advice) { try consumer.resume(advice) }
    }
    public func setMuted(_ muted: Bool, for advice: AdmittedCoachingAdvice) throws {
        try authorized(advice) { try consumer.setMuted(muted, for: advice) }
    }

    private func authorized(_ advice: AdmittedCoachingAdvice, perform: () throws -> Void) throws {
        guard let renderer else { try perform(); return } // Injected trusted players retain the core contract.
        try renderer.withAuthorization({ [session] in (try? session.validate(advice.ticket)) != nil },
                                       perform: perform)
    }

    /// Owner must call on connection/permission/participant-awareness loss, before any route rebuilding.
    public func invalidate() { monitor.disarm(); consumer.invalidate() }
    public func stop() { monitor.disarm(); consumer.stop() }
}
