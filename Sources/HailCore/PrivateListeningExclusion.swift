public import Observation

/// Ambient capture and private coaching never hold the microphone together (#645). Each side claims synchronously
/// on the main actor before any permission prompt, connection or child start, so neither can slip in during the
/// other's startup window. A platform opts in by handing both controllers the same instance; iOS does not yet.
@MainActor @Observable
public final class PrivateListeningExclusion {
    public static let shared = PrivateListeningExclusion()

    /// From the ambient toggle's request until any stop, matching `AmbientListeningController.isOn`.
    public private(set) var ambientOn = false
    /// From coaching Start until its child has exited.
    public private(set) var coachingHoldsAudio = false

    public init() {}

    /// False while coaching holds audio; the ambient request is then refused, not queued.
    public func claimAmbient() -> Bool {
        guard !coachingHoldsAudio else { return false }
        ambientOn = true
        return true
    }

    public func releaseAmbient() { ambientOn = false }

    /// False while ambient is on or another coaching run still holds audio.
    public func claimCoaching() -> Bool {
        guard !ambientOn, !coachingHoldsAudio else { return false }
        coachingHoldsAudio = true
        return true
    }

    public func releaseCoaching() { coachingHoldsAudio = false }
}
