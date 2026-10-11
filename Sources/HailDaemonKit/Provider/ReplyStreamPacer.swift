import Foundation

package enum ReplyStreamPacerError: Error, Sendable, Equatable {
    case audioBoundExceeded
}

/// Paces one reply job's frames so a long spoken answer plays in full (#430) instead of stopping at the old
/// one-minute frame budget (about 146 s of speech).
///
/// - Rate: at most `framesPerMinute` frames in any 60 s, below the reply endpoint's shared
///   `LocalReplyEndpoint.maxFramesPerMinute`, so one job never trips it on its own.
/// - Lead: audio is sent at most `leadSeconds` ahead of real time since its first frame, which bounds what the
///   phone has to buffer however long the reply is.
/// - Bound: `maxAudioSeconds` of audio per job. Not a listening limit, a stop for a renderer that never ends.
///
/// Pacing is a courtesy that keeps a long reply under the endpoint's limits; the endpoint's own rate limit, and
/// the request, lease, permit and selection checks on every frame, are unchanged.
package struct ReplyStreamPacer: Sendable {
    package static let framesPerMinute = 100
    package static let leadSeconds = 20.0
    package static let maxAudioSeconds = 30.0 * 60

    private let paced: Bool
    private var start: ContinuousClock.Instant?
    private var audioSeconds = 0.0
    /// When each of the last `framesPerMinute` frames may be sent, oldest first; bounded.
    private var recent: [ContinuousClock.Instant] = []

    package init(paced: Bool = true) { self.paced = paced }

    /// Admits one frame carrying `audio` seconds (zero for text or a terminal marker) and returns the instant
    /// it may be sent. Throws, admitting nothing, once the job's audio would pass `maxAudioSeconds`.
    package mutating func admit(audio: Double, at now: ContinuousClock.Instant) throws -> ContinuousClock.Instant {
        guard audio >= 0, audioSeconds + audio <= Self.maxAudioSeconds else {
            throw ReplyStreamPacerError.audioBoundExceeded
        }
        var sendAt = now
        if paced {
            if audio > 0 {
                let first = start ?? now
                start = first
                sendAt = max(sendAt, first.advanced(by: .seconds(max(0, audioSeconds - Self.leadSeconds))))
            }
            if recent.count >= Self.framesPerMinute {
                sendAt = max(sendAt, recent[recent.count - Self.framesPerMinute].advanced(by: .seconds(60)))
            }
            recent.append(sendAt)
            if recent.count > Self.framesPerMinute { recent.removeFirst(recent.count - Self.framesPerMinute) }
        }
        audioSeconds += audio
        return sendAt
    }

    /// Seconds of 16-bit mono PCM in `bytes` at `sampleRate`.
    package static func seconds(pcm16Bytes bytes: Int, sampleRate: Int) -> Double {
        sampleRate > 0 ? Double(bytes) / Double(2 * sampleRate) : 0
    }
}

/// One job's pacer and its clock; waits are cancellable, so a cancelled reply stops at once.
package actor ReplyStreamPacing {
    private var pacer: ReplyStreamPacer

    package init(paced: Bool = true) { pacer = ReplyStreamPacer(paced: paced) }

    /// `HAILD_REPLY_PACING=off` sends as fast as the endpoint answers (tests and diagnostics). The endpoint's
    /// own per-minute limit still applies, so this can only make a long reply fail sooner, never exceed it.
    package static func fromEnvironment(_ environment: [String: String]) -> ReplyStreamPacing {
        ReplyStreamPacing(paced: environment["HAILD_REPLY_PACING"] != "off")
    }

    package func admit(audio: Double) async throws {
        let sendAt = try pacer.admit(audio: audio, at: .now)
        if sendAt > .now { try await Task.sleep(until: sendAt, clock: .continuous) }
    }
}
