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

    /// Announces once each reply whose audio did not play (#825), while `when` allows: a stream that ended early is
    /// spoken; a failed playback goes straight to the fallback, since the player that failed would play this too.
    public func watchReplyAudio(when allowed: @escaping @MainActor () -> Bool) {
        let problems = withObservationTracking { playback.audioProblems } onChange: { [weak self] in
            Task { @MainActor in self?.watchReplyAudio(when: allowed) }
        }
        for (id, problem) in problems where announcedReplies.insert(id).inserted && allowed() {
            if problem == ReplyPlaybackController.audioDidNotArrive {
                announce(.replyAudioLost)
            } else {
                fallBack(.replyAudioFailed, .playerFailed)
            }
        }
    }

    private func fallBack(_ announcement: Announcement, _ reason: Fallback) {
        Self.log.notice("announcement_suppressed key=\(announcement.rawValue) reason=\(reason.rawValue)")
        fallback(announcement, reason)
    }
}

extension ReplyStreamKey {
    static let announcementEndpoint: HostEndpoint.Identifier = "local-announcement"
    var isAnnouncement: Bool { endpointID == Self.announcementEndpoint }
}

extension ReplyPlaybackController {
    /// Every reply whose audio did not play, by presentation id, observably.
    var audioProblems: [String: String] { presentationStatuses.compactMapValues(Self.audioProblem) }

    /// Queues a local announcement behind any reply (#825 S4b). It plays through the same player, so it shares the
    /// echo canceller, pause and mute, and playback reports it as assistant speech like a reply; it is never a reply
    /// entry, and never what Replay replays.
    func enqueueAnnouncement(_ audio: [AudioPayload]) {
        let key = ReplyStreamKey(endpointID: ReplyStreamKey.announcementEndpoint, replyID: UUID())
        var stream = ReplyStreamState()
        for payload in audio { stream.segments[payload.sequence] = payload }
        streams[key] = stream
        queue.append(key)
        drain()
    }
}

/// A bundled clip named `announce-<key>` (mono, its words exactly the key's text, #820), or else the system voice
/// rendered to buffers with `AVSpeechSynthesizer.write`, never `speak`, so nothing is heard outside the reply player.
@MainActor
public final class LocalAnnouncementRenderer: AnnouncementRendering {
    private let synthesizer = AVSpeechSynthesizer()
    private static let segmentFrames = 24_000 // 1 s of 24 kHz audio per payload, under the 64 KiB frame cap.

    public init() {}

    public func audio(for announcement: Announcement) async throws -> [AudioPayload] {
        var audio = try clip(announcement)
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

    /// The synthesizer calls back off the main actor, so samples are gathered under a lock, as plain values.
    private func spoken(_ text: String) async -> ([Int16], Int) {
        let utterance = AVSpeechUtterance(string: text)
        let gathered = SpokenSamples()
        return await withCheckedContinuation { continuation in
            synthesizer.write(utterance) { buffer in
                guard let pcm = buffer as? AVAudioPCMBuffer, pcm.frameLength > 0 else {
                    // A zero-length buffer ends the utterance.
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
