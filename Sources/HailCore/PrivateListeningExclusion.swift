public import Foundation
public import Observation

/// Ambient capture and private coaching never hold the microphone together (#645). Each side claims synchronously
/// on the main actor before any permission prompt, connection or child start, so neither can slip in during the
/// other's startup window. A claim is a token: only its holder can release it, so a late or stale release from an
/// earlier run cannot clear a newer claim. A platform opts in by sharing one instance; iOS does not yet.
@MainActor @Observable
public final class PrivateListeningExclusion {
    public static let shared = PrivateListeningExclusion()

    private var ambient: UUID?
    private var coaching: UUID?

    /// From the ambient toggle's request until any stop, matching `AmbientListeningController.isOn`.
    public var ambientOn: Bool { ambient != nil }
    /// From coaching Start until its child has exited.
    public var coachingHoldsAudio: Bool { coaching != nil }

    public init() {}

    /// Nil while coaching holds audio or ambient is already claimed; the request is then refused, not queued.
    public func claimAmbient() -> UUID? {
        guard coaching == nil, ambient == nil else { return nil }
        let token = UUID()
        ambient = token
        return token
    }

    public func releaseAmbient(_ token: UUID) { if ambient == token { ambient = nil } }

    /// Nil while ambient is on or another coaching run still holds audio.
    public func claimCoaching() -> UUID? {
        guard ambient == nil, coaching == nil else { return nil }
        let token = UUID()
        coaching = token
        return token
    }

    public func releaseCoaching(_ token: UUID) { if coaching == token { coaching = nil } }
}
