#if os(iOS)
import AVFAudio
public import Foundation
#endif
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
@MainActor
public final class BackgroundKeepalive {
    public private(set) var isRunning = false
    public var sceneActive = true { didSet { update() } }
    private(set) var hostReady = false
    private(set) var ambientStreaming = false
    /// While true, stopping leaves the session active so the reply keeps playing.
    public var isReplyAudible: @MainActor () -> Bool = { false }
    private var held = false
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

    func observe(hostReady: Bool, ambientStreaming: Bool) {
        self.hostReady = hostReady
        self.ambientStreaming = ambientStreaming
        update()
    }

    /// Someone else deactivated the session under the keepalive: ambient listening releasing it as it ends in the
    /// background. Rendering starts again in a fresh session.
    public func sessionWasReleased() {
        guard isRunning else { return }
        renderer.stop(releasingSession: false)
        isRunning = false
        update()
    }

    private func update() {
        let wanted = BackgroundKeepalivePolicy.shouldRun(
            sceneActive: sceneActive, hostReady: hostReady, ambientStreaming: ambientStreaming
        )
        if !wanted { held = false }
        if wanted, !held, !isRunning {
            do {
                try renderer.start()
                isRunning = true
            } catch {
                held = true
            }
        } else if !wanted, isRunning {
            renderer.stop(releasingSession: !isReplyAudible())
            isRunning = false
        }
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

#if os(iOS)
/// Loops silence through an output-only engine: iOS keeps an audio-background app running only while it renders.
/// `.playback` with `.mixWithOthers` has no input (no mic, no indicator) and leaves other apps' audio undisturbed;
/// replies arriving meanwhile play within it (`PCM16AudioPlayer`). A releasing stop deactivates with
/// `.notifyOthersOnDeactivation` and restores the category it found.
@MainActor
public final class SilentAudioKeepalive: NSObject, BackgroundKeepaliveRendering {
    public var onEvent: (@MainActor (BackgroundKeepaliveEvent) -> Void)?
    private let session = AVAudioSession.sharedInstance()
    private var engine: AVAudioEngine?
    /// What the keepalive found, restored when it releases the session. Station audio always uses the default mode.
    private var found: (category: AVAudioSession.Category, options: AVAudioSession.CategoryOptions)?

    override public init() {
        super.init()
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(interruption), name: AVAudioSession.interruptionNotification,
                           object: session)
    }

    public func start() throws {
        if !holdsCategory { found = (session.category, session.categoryOptions) }
        do {
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            try startEngine()
        } catch {
            stop(releasingSession: true)
            throw error
        }
    }

    public func stop(releasingSession: Bool) {
        if let engine {
            NotificationCenter.default.removeObserver(self, name: .AVAudioEngineConfigurationChange, object: engine)
            engine.stop()
        }
        engine = nil
        guard releasingSession else { return }
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        if holdsCategory, let found { try? session.setCategory(found.category, mode: .default, options: found.options) }
        found = nil
    }

    /// Still the category the keepalive set: nothing (tap-to-talk, ambient) has configured the session since.
    private var holdsCategory: Bool {
        session.category == .playback && session.categoryOptions.contains(.mixWithOthers)
    }

    private func startEngine() throws {
        guard let format = AVAudioFormat(standardFormatWithSampleRate: 44_100, channels: 1),
              let silence = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_410),
              let samples = silence.floatChannelData?.pointee else { throw ReplyAudioPlayerError.invalidBuffer }
        silence.frameLength = silence.frameCapacity
        samples.update(repeating: 0, count: Int(silence.frameLength))
        let engine = AVAudioEngine()
        let node = AVAudioPlayerNode()
        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        node.scheduleBuffer(silence, at: nil, options: .loops)
        try engine.start()
        node.play()
        self.engine = engine
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(configurationChanged), name: .AVAudioEngineConfigurationChange,
                           object: engine)
    }

    /// A route change stops the engine; restart it, or report the stop if that fails.
    private func restart() {
        guard let engine, !engine.isRunning else { return }
        stop(releasingSession: false)
        do { try startEngine() } catch { onEvent?(.interrupted) }
    }

    private func interrupted(began: Bool, shouldResume: Bool) {
        if !began {
            onEvent?(.interruptionEnded(shouldResume: shouldResume))
        } else if engine != nil {
            stop(releasingSession: false)
            onEvent?(.interrupted)
        }
    }

    // AVFoundation posts these off the main thread.
    @objc nonisolated private func configurationChanged() { Task { @MainActor in self.restart() } }

    @objc nonisolated private func interruption(_ notification: Notification) {
        let type = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
        let options = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
        let began = type == AVAudioSession.InterruptionType.began.rawValue
        let shouldResume = AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume)
        Task { @MainActor in self.interrupted(began: began, shouldResume: shouldResume) }
    }
}
#endif
