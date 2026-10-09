import Observation

/// Keeps the station running in the background while a host is connected (#352), so tap-to-talk keeps its connection
/// across a focus change. Ambient listening keeps the app alive on its own (#282); the keepalive never runs with it.
public enum BackgroundKeepalivePolicy {
    public static func shouldRun(sceneActive: Bool, hostReady: Bool, ambientStreaming: Bool) -> Bool {
        !sceneActive && hostReady && !ambientStreaming
    }
}

public enum BackgroundKeepaliveEvent: Sendable, Equatable {
    /// The system stopped rendering: an interruption began, or a restart after a route change failed.
    case interrupted
    case interruptionEnded(shouldResume: Bool)
}

/// Renders the keepalive. `stop` releases the audio session only when told to, so an audible reply is not cut off.
@MainActor
public protocol BackgroundKeepaliveRendering: AnyObject {
    var onEvent: (@MainActor (BackgroundKeepaliveEvent) -> Void)? { get set }
    func start() throws
    func stop(releasingSession: Bool)
}

/// Starts and stops the renderer as the policy's inputs change. After an interruption or a failed start it waits
/// for the interruption to end with `shouldResume` or for the policy to stop wanting it: it never fights for audio.
/// `ownsSession` outlives `isRunning`, so whenever the policy stops wanting it (#354), a session the keepalive
/// configured is released: after an interruption, or once a reply that kept it active has finished.
@MainActor
public final class BackgroundKeepalive {
    public private(set) var isRunning = false
    /// False only once the scene is in the background, not merely inactive (#354).
    public var sceneActive = true { didSet { update() } }
    private(set) var hostReady = false
    private(set) var ambientStreaming = false
    /// While true, stopping leaves the session active so the reply keeps playing.
    public var isReplyAudible: @MainActor () -> Bool = { false }
    /// Set by a start, cleared only by a releasing stop: an interruption or an audible reply stops rendering but
    /// leaves the keepalive's category installed, and a later releasing stop must still restore it.
    private(set) var ownsSession = false
    private var held = false
    private var followsReplies = false
    private let renderer: any BackgroundKeepaliveRendering

    public init(renderer: any BackgroundKeepaliveRendering) {
        self.renderer = renderer
        renderer.onEvent = { [weak self] in self?.handle($0) }
    }

    /// Follows host readiness and ambient streaming without view updates, so it works in the background too.
    public func follow(_ store: HostConnectionStore) {
        let (ready, streaming) = withObservationTracking {
            (store.hosts.contains { $0.state == .ready }, store.ambientStreaming)
        } onChange: { [weak self, weak store] in
            Task { @MainActor in if let store { self?.follow(store) } }
        }
        observe(hostReady: ready, ambientStreaming: streaming)
    }

    /// Follows reply audibility, so a session left active for an audible reply is released once it ends (#354).
    public func follow(_ playback: ReplyPlaybackController) {
        guard !followsReplies else { return }
        followsReplies = true
        // An active reply holds the session even while muted: unmuting only changes the node's volume and never
        // reactivates the session, so releasing on mute would leave the rest of the reply silent. A paused reply
        // may release; resuming prepares the player again, which reactivates it.
        isReplyAudible = { [weak playback] in
            guard let playback else { return false }
            return playback.activeKey != nil && !playback.isPaused && !playback.isCaptureSuppressed
        }
        track(playback)
    }

    private func track(_ playback: ReplyPlaybackController) {
        withObservationTracking {
            _ = (playback.activeKey, playback.isPaused, playback.isMuted, playback.isCaptureSuppressed)
        } onChange: { [weak self, weak playback] in
            Task { @MainActor in
                guard let self, let playback else { return }
                self.track(playback)
                self.update()
            }
        }
    }

    func observe(hostReady: Bool, ambientStreaming: Bool) {
        self.hostReady = hostReady
        self.ambientStreaming = ambientStreaming
        update()
    }

    /// Someone else deactivated the session under the keepalive: ambient listening releasing it as it ends in the
    /// background. Rendering starts again in a fresh session, and a start that failed while ambient still held the
    /// session gets its retry now (#354).
    public func sessionWasReleased() {
        guard isRunning || held || ownsSession else { return }
        if isRunning {
            renderer.stop(releasingSession: false)
            isRunning = false
        }
        held = false
        update()
    }

    private func update() {
        let wanted = BackgroundKeepalivePolicy.shouldRun(
            sceneActive: sceneActive, hostReady: hostReady, ambientStreaming: ambientStreaming
        )
        if wanted {
            guard !held, !isRunning else { return }
            do {
                try renderer.start()
                isRunning = true
                ownsSession = true
            } catch {
                // The renderer released whatever it had configured before throwing.
                ownsSession = false
                held = true
            }
            return
        }
        held = false
        guard isRunning || ownsSession else { return }
        let releasing = !isReplyAudible()
        // Not rendering and a reply still audible: nothing to do until the reply ends.
        guard isRunning || releasing else { return }
        renderer.stop(releasingSession: releasing)
        isRunning = false
        if releasing { ownsSession = false }
    }

    private func handle(_ event: BackgroundKeepaliveEvent) {
        switch event {
        case .interrupted:
            guard isRunning else { return }
            renderer.stop(releasingSession: false)
            isRunning = false
            held = true
        case .interruptionEnded(let shouldResume):
            guard held, shouldResume else { return }
            held = false
            update()
        }
    }
}
