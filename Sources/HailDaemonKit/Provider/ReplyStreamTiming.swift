import os
import Synchronization

private let timingLogger = Logger(subsystem: "com.mickdarling.hailing-station", category: "reply-timing")

/// One spoken reply's delivery timing (#737), so choppy playback shows in data. The device plays a reply from its
/// first frame with no reserve, so when a frame is acknowledged its queue holds the audio acknowledged before it less
/// the time since the first frame was: the lead. Below about -100 ms (the device's lead-in silence) the device very
/// likely ran dry because the Mac fell behind real time (TTS starved of CPU or memory), unless it was still playing
/// an earlier reply or was paused, which hold a reply back. Gaps the device counts while the lead stayed positive
/// point at transport or the device instead. A frame's acknowledgement time covers the endpoint's audit write and
/// publication, and any resend waits after a `rate limited` or `requestPending` refusal, which the log line counts.
package struct ReplyStreamTiming: Sendable, Equatable {
    package struct Summary: Sendable, Equatable {
        package var frames = 0
        package var audio: Duration = .zero
        package var firstAudio: Duration?
        package var minimumLead: Duration?
        package var slowestAcknowledgement: Duration = .zero
        package var acknowledgementP95: Duration = .zero
        package var wall: Duration = .zero
    }

    private let started: ContinuousClock.Instant
    private var firstAcknowledged: ContinuousClock.Instant?
    private var audio: Duration = .zero
    private var minimumLead: Duration?
    private var acknowledgements: [Duration] = []

    package init(startedAt started: ContinuousClock.Instant) { self.started = started }

    /// A frame of `audio` was sent at `sentAt` and acknowledged `acknowledgedAfter` later, when the device has it.
    package mutating func sent(
        audio frameAudio: Duration, at sentAt: ContinuousClock.Instant, acknowledgedAfter acknowledgement: Duration
    ) {
        let acknowledged = sentAt + acknowledgement
        if let firstAcknowledged {
            let lead = audio - (acknowledged - firstAcknowledged)
            minimumLead = min(minimumLead ?? lead, lead)
        } else {
            firstAcknowledged = acknowledged
        }
        audio += frameAudio
        acknowledgements.append(acknowledgement)
    }

    package func summary(at end: ContinuousClock.Instant) -> Summary {
        let sorted = acknowledgements.sorted()
        let p95 = sorted.isEmpty ? Duration.zero : sorted[min(sorted.count - 1, (sorted.count * 95 + 99) / 100 - 1)]
        return Summary(
            frames: acknowledgements.count, audio: audio, firstAudio: firstAcknowledged.map { $0 - started },
            minimumLead: minimumLead, slowestAcknowledgement: sorted.last ?? .zero, acknowledgementP95: p95,
            wall: end - started
        )
    }
}

extension ReplyStreamTiming.Summary {
    /// One log line, numbers only.
    package var line: String {
        func ms(_ value: Duration?) -> String { value.map { String(Int64($0 / .milliseconds(1))) } ?? "none" }
        return "reply audio: frames=\(frames) audio_ms=\(ms(audio)) first_audio_ms=\(ms(firstAudio)) "
            + "min_lead_ms=\(ms(minimumLead)) ack_max_ms=\(ms(slowestAcknowledgement)) "
            + "ack_p95_ms=\(ms(acknowledgementP95)) wall_ms=\(ms(wall))"
    }
}

/// A reply job's timing, shared by the frames it sends; logged once as the reply ends.
package final class ReplyTimingRecorder: Sendable {
    private let timing: Mutex<ReplyStreamTiming>

    package init(startedAt started: ContinuousClock.Instant = .now) {
        timing = Mutex(ReplyStreamTiming(startedAt: started))
    }

    package func sent(audio: Duration, at sentAt: ContinuousClock.Instant, acknowledgedAfter: Duration) {
        timing.withLock { $0.sent(audio: audio, at: sentAt, acknowledgedAfter: acknowledgedAfter) }
    }

    /// Logs the summary to the unified log (`log show --predicate 'category == "reply-timing"'`). `line` is built
    /// from numbers only, and `outcome` is one of a few fixed words, so both are public. A reply that sent its audio
    /// some other way (vbsay's file mode) measured nothing and says so.
    package func log(outcome: String, resends: Int, at end: ContinuousClock.Instant = .now) {
        let summary = timing.withLock { $0.summary(at: end) }
        let outcome = outcome == "played" && summary.frames == 0 ? "played_unmeasured" : outcome
        let line = summary.line
        timingLogger.notice("\(line, privacy: .public) resends=\(resends) outcome=\(outcome, privacy: .public)")
    }
}
