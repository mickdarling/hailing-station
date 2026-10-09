#if os(iOS)
import AVFAudio
public import Foundation

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
        defer { found = nil }
        // Capture (tap-to-talk, ambient) has configured the session since: it is theirs, active or not (#354).
        guard holdsCategory else { return }
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        if let found { try? session.setCategory(found.category, mode: .default, options: found.options) }
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
