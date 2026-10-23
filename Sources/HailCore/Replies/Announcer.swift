import AVFoundation
public import HailProtocol
import os

/// Turns an announcement into reply audio (#825 S4b): a bundled clip, or the system voice rendered to buffers. It never
/// speaks aloud itself, so every announcement plays through the reply player and the capture engine's echo canceller,
/// and is never heard by the microphone as speech.
@MainActor
public protocol AnnouncementRendering {
    func audio(for announcement: Announcement) async throws -> [AudioPayload]
}

/// Speaks short announcements the app makes itself, through the reply queue (#825 S4b, #822). One plays after any reply
/// already queued, never interrupting or reordering it, and pause and listening's suppression hold it like a reply.
/// When replies are muted, or no audio can be made, it is never silently lost: `fallback` shows and signals it instead,
/// and the unified log records the key and why.
@MainActor
public final class Announcer {
    public enum Fallback: String, Sendable {
        case muted, renderFailed = "render_failed", playerFailed = "player_failed"
    }

    private let playback: ReplyPlaybackController
    private let renderer: any AnnouncementRendering
    private let fallback: @MainActor (Announcement, Fallback) -> Void
    private var announcedReplies: Set<String> = []
    private static let log = Logger(subsystem: "com.mickdarling.hailing-station", category: "announcements")

    public init(playback: ReplyPlaybackController, renderer: any AnnouncementRendering,
                fallback: @escaping @MainActor (Announcement, Fallback) -> Void) {
        (self.playback, self.renderer, self.fallback) = (playback, renderer, fallback)
    }

    public func announce(_ announcement: Announcement) {
        guard !playback.isMuted else { return fallBack(announcement, .muted) }
        Task { @MainActor in
            do {
                let audio = try await renderer.audio(for: announcement)
                guard audio.last?.isFinal == true else { throw ReplyAudioPlayerError.invalidBuffer }
                guard !playback.isMuted else { return fallBack(announcement, .muted) }
                playback.enqueueAnnouncement(audio)
            } catch {
                fallBack(announcement, .renderFailed)
            }
        }
    }

    /// Announces once each reply whose audio did not play (#825), while `when` allows: a stream that ended early, or
    /// unplayable or undecodable audio is spoken; player failures and unknown statuses use the fallback (#825).
    public func watchReplyAudio(when allowed: @escaping @MainActor () -> Bool) {
        let lost = withObservationTracking { playback.lostAudioStatuses } onChange: { [weak self] in
            Task { @MainActor in self?.watchReplyAudio(when: allowed) }
        }
        // Skipped losses stay once-only: VoiceOver owned them even if it later turns off (#825, #86).
        // Keep their statuses eligible for deferred VoiceOver across trims; without app acknowledgement,
        // only the bounded, oldest-first seenFrameLimit eviction releases their retention (#825, #86).
        for (id, status) in lost where announcedReplies.insert(id).inserted {
            if allowed() {
                announceAudioProblem(status)
                playback.acknowledgeAudioLoss(id)
            }
        }
    }

    func announceAudioProblem(_ status: String?) {
        switch status {
        case ReplyPlaybackController.abandonedStatus: announce(.replyAudioLost)
        case ReplyPlaybackController.audioFormatNotPlayable, ReplyPlaybackController.audioCouldNotBeDecoded:
            announce(.replyAudioFailed)
        case ReplyPlaybackController.playbackFailed: fallBack(.replyAudioFailed, .playerFailed)
        default: fallBack(.replyAudioFailed, .playerFailed)
        }
    }

    private func fallBack(_ announcement: Announcement, _ reason: Fallback) {
        Self.log.notice("announcement_suppressed key=\(announcement.rawValue) reason=\(reason.rawValue)")
        fallback(announcement, reason)
    }
}

/// A bundled clip named `announce-<key>` (mono, its words exactly the key's text, #820), or else the system voice
/// rendered to buffers with `AVSpeechSynthesizer.write`, never `speak`, so nothing is heard outside the reply player.
@MainActor
public final class LocalAnnouncementRenderer: AnnouncementRendering {
    private var synthesizer: AVSpeechSynthesizer
    private let makeSynthesizer: @MainActor () -> AVSpeechSynthesizer
    private let waitForDeadline: @MainActor () async -> Void
    private static let segmentFrames = 24_000 // 1 s at 24 kHz per payload; local, so no wire frame cap applies.
    static let renderDeadline: Duration = .seconds(20) // A loaded host took 9 s to render one (#838 review).

    public convenience init() {
        self.init(makeSynthesizer: { AVSpeechSynthesizer() },
                  waitForDeadline: { try? await Task.sleep(for: Self.renderDeadline) })
    }

    init(makeSynthesizer: @escaping @MainActor () -> AVSpeechSynthesizer,
         waitForDeadline: @escaping @MainActor () async -> Void) {
        (self.makeSynthesizer, self.synthesizer, self.waitForDeadline) =
            (makeSynthesizer, makeSynthesizer(), waitForDeadline)
    }

    public func audio(for announcement: Announcement) async throws -> [AudioPayload] {
        // A clip that exists but can't be read falls back to the system voice, never to silence.
        var audio = try? clip(announcement)
        if audio == nil { audio = await spoken(announcement.fallbackText) }
        guard let (samples, rate) = audio, !samples.isEmpty, rate > 0 else { throw ReplyAudioPlayerError.invalidBuffer }
        let stream = UUID()
        let step = Self.segmentFrames * rate / 24_000
        return stride(from: 0, to: samples.count, by: step).enumerated().map { index, start in
            let chunk = samples[start..<min(start + step, samples.count)]
            let bytes = chunk.withUnsafeBytes { Data($0) } // Little-endian on every Apple platform.
            return AudioPayload(codec: .pcm16, sampleRate: rate, channels: 1, sequence: index, streamID: stream,
                                isFinal: start + step >= samples.count, bytes: bytes)
        }
    }

    private func clip(_ announcement: Announcement) throws -> ([Int16], Int)? {
        guard let url = Bundle.main.url(forResource: "announce-\(announcement.rawValue)", withExtension: "caf") else {
            return nil
        }
        let file = try AVAudioFile(forReading: url)
        guard let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat,
                                            frameCapacity: AVAudioFrameCount(file.length)) else { return nil }
        try file.read(into: buffer)
        return (Self.int16Samples(buffer), Int(buffer.format.sampleRate))
    }

    /// The synthesizer calls back off the main actor, so samples are gathered under a lock, as plain values. If it
    /// hasn't ended the utterance by the deadline, nothing is played (never a cut-off cue) and the cue falls back
    /// instead of hanging; late callbacks are ignored (#838 review).
    private func spoken(_ text: String) async -> ([Int16], Int) {
        let utterance = AVSpeechUtterance(string: text)
        let gathered = SpokenSamples()
        let synthesizer = synthesizer
        return await withCheckedContinuation { continuation in
            Task {
                await waitForDeadline()
                guard gathered.finish() != nil else { return }
                if self.synthesizer === synthesizer {
                    synthesizer.stopSpeaking(at: .immediate)
                    self.synthesizer = makeSynthesizer()
                }
                // Old queued writes may lose callbacks; each safely falls back at its own deadline (#825).
                continuation.resume(returning: ([], 0))
            }
            // Sendable, so it never inherits the main actor: the synthesizer may call back on any thread (#838 review).
            synthesizer.write(utterance) { @Sendable buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
                    if let result = gathered.finish() { continuation.resume(returning: result) }
                    return
                }
                gathered.append(Self.int16Samples(pcm), rate: Int(pcm.format.sampleRate))
            }
        }
    }

    /// Mono 16-bit samples from a buffer the synthesizer or a clip produced, in either sample format.
    nonisolated static func int16Samples(_ buffer: AVAudioPCMBuffer) -> [Int16] {
        let count = Int(buffer.frameLength)
        if let samples = buffer.int16ChannelData?.pointee {
            return Array(UnsafeBufferPointer(start: samples, count: count))
        }
        guard let floats = buffer.floatChannelData?.pointee else { return [] }
        return (0..<count).map { Int16(max(-1, min(1, floats[$0])) * Float(Int16.max)) }
    }
}

/// Samples the synthesizer hands over on its own thread, gathered once and finished once.
private final class SpokenSamples: @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Int16] = []
    private var rate = 0
    private var finished = false

    func append(_ more: [Int16], rate: Int) {
        lock.withLock {
            guard !finished else { return }
            samples += more
            self.rate = rate
        }
    }

    /// The gathered samples the first time, nil after.
    func finish() -> ([Int16], Int)? {
        lock.withLock {
            guard !finished else { return nil }
            finished = true
            return (samples, rate)
        }
    }
}
