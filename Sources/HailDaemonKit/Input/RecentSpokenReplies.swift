#if os(macOS)
import Foundation
import HailProtocol
import Synchronization

/// Own-voice rejection for ambient listening (#269 stage 1). Once the phone's mic stays open while a reply plays,
/// echo cancellation can leak some of the reply back into RightyO, which could then dispatch the assistant's own
/// words as a request. The host knows exactly what it is speaking, so an ambient request whose words largely
/// repeat a reply that is playing, or just finished, is dropped. Kept in memory only, never logged.
final class RecentSpokenReplies: Sendable {
    /// How long after a reply's estimated end of playback its words still count as "just said": phone buffering,
    /// network delay and RightyO's own endpointing all land after the last sample is sent.
    static let hold: Duration = .seconds(4)
    /// Fraction of a heard request's word pairs found in a reply that marks it as the reply's echo.
    static let echoThreshold = 0.6
    static let maxReplies = 8
    /// Shorter requests are never treated as echo: "stop" or "wait" must reach the assistant even when the reply
    /// itself contains the word.
    static let minimumWords = 3

    private struct Reply {
        var words: [String]
        var audioSeconds: Double = 0
        var firstAudio: ContinuousClock.Instant?
        var lastSeen: ContinuousClock.Instant
        var expires: ContinuousClock.Instant {
            let playEnd = firstAudio.map { $0.advanced(by: .seconds(audioSeconds)) } ?? lastSeen
            return max(playEnd, lastSeen).advanced(by: RecentSpokenReplies.hold)
        }
    }

    private let replies = Mutex<[UUID: Reply]>([:])
    private let now: @Sendable () -> ContinuousClock.Instant

    init(now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.now = now
    }

    /// Records a reply frame the host delivered: its text, or how much audio it has sent so far.
    func observe(_ frame: Frame) {
        let instant = now()
        replies.withLock { replies in
            switch frame.payload {
            case .text(let text):
                guard let reply = text.reply else { return }
                replies[reply.id, default: Reply(words: [], lastSeen: instant)].words = Self.words(text.text)
                replies[reply.id]?.lastSeen = instant
            case .audio(let audio):
                guard let reply = audio.reply, audio.codec == .pcm16, audio.sampleRate > 0, audio.channels > 0 else {
                    return
                }
                var entry = replies[reply.id] ?? Reply(words: [], lastSeen: instant)
                entry.firstAudio = entry.firstAudio ?? instant
                entry.audioSeconds += Double(audio.bytes.count) / Double(2 * audio.channels * audio.sampleRate)
                entry.lastSeen = instant
                replies[reply.id] = entry
            default: return
            }
            replies = replies.filter { $0.value.expires > instant }
            while replies.count > Self.maxReplies,
                  let oldest = replies.min(by: { $0.value.lastSeen < $1.value.lastSeen }) {
                replies.removeValue(forKey: oldest.key)
            }
        }
    }

    /// True when `heard` reads as the echo of a reply still playing or within `hold` of its end.
    func isEcho(_ heard: String) -> Bool {
        let instant = now()
        let heardWords = Self.words(heard)
        guard heardWords.count >= Self.minimumWords else { return false }
        return replies.withLock { replies in
            replies.values.contains { $0.expires > instant && Self.overlap(heardWords, $0.words) >= Self.echoThreshold }
        }
    }

    /// Lower-cased letter/digit runs, so punctuation and transcription casing don't matter.
    static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// Fraction of `heard`'s adjacent word pairs that also occur in `reply`.
    static func overlap(_ heard: [String], _ reply: [String]) -> Double {
        guard heard.count > 1, reply.count > 1 else { return 0 }
        let replyPairs = Set(zip(reply, reply.dropFirst()).map { "\($0) \($1)" })
        let heardPairs = zip(heard, heard.dropFirst()).map { "\($0) \($1)" }
        let found = heardPairs.filter { replyPairs.contains($0) }.count
        return Double(found) / Double(heardPairs.count)
    }
}
#endif
