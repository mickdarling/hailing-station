public import Foundation
public import HailProtocol

/// Trusted local controls only. Conversation/model output never enters this interface.
public enum ForegroundCoachingControl: Sendable {
    case enable(sessionID: UUID, destinationID: UUID, listenerID: String)
    case qualify(CoachingQualification)
    case disable(sessionID: UUID)
}

/// Provider-neutral owned child boundary; adapters perform bounded PCM conversion and wire encoding.
/// Construction is inert: no ASR/provider work before enable AND qualification. Close must synchronously
/// abandon input/control; stop joins only this owned child. No action-dispatch capability is provided.
@MainActor public protocol ForegroundCoachingTransport: AnyObject {
    func send(_ control: ForegroundCoachingControl) -> Bool
    func write(_ buffer: AudioCaptureBuffer) -> Bool
    func close()
    func stop() async
}

/// The existing private route/consumer gate, not ordinary reply playback.
@MainActor public protocol ForegroundCoachingAudio: AnyObject {
    func begin(sessionID: UUID, destinationID: UUID, consentConfirmed: Bool) throws -> CoachingQualification
    func renew(_ lease: CoachingQualification) throws -> CoachingQualification
    func admit(_ data: Data) throws -> AdmittedCoachingAdvice
    func prepareSpeech(_ advice: AdmittedCoachingAdvice) throws -> AdmittedCoachingAdvice
    func interruptSpeech()
    func playCompletePhrase(_ payloads: [AudioPayload], for advice: AdmittedCoachingAdvice) throws
    func schedule(_ payload: AudioPayload, for advice: AdmittedCoachingAdvice) throws
    func resume(_ advice: AdmittedCoachingAdvice) throws
    func stop()
}

extension ApplePrivateCoaching: ForegroundCoachingAudio {}

/// Replaceable TTS only. Emit every chunk through the immutable advice gate. Cancellation must retire
/// owned renderer resources; render returns only after its ownership/cleanup responsibility is settled.
@MainActor public protocol ForegroundCoachingSpeech: AnyObject {
    func render(_ text: String, emit: @escaping @MainActor (AudioPayload) throws -> Void) async throws
    func cancel()
}

public enum ForegroundCoachingError: Error, Equatable {
    case busy, awarenessRequired, invalidListener, startupLost, transportFailed, invalidSpeech
}

/// Content-free status. Retiring is deliberately not off: no successor may allocate a child/TTS slot
/// until old asynchronous jobs return, even when cancellation is noncooperative.
public enum ForegroundCoachingStatus: Sendable, Equatable { case off, starting, active, retiring }
