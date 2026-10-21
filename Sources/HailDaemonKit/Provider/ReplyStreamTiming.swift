import os
import Synchronization

private let timingLogger = Logger(subsystem: "com.mickdarling.hailing-station", category: "reply-timing")

/// One spoken reply's delivery timing (#737), so choppy playback shows in data. The device plays a reply from its
/// first frame with no reserve, so its queue holds the audio sent so far less the time since that first frame: the
/// lead. A lead below zero means the device ran dry because rendering fell behind real time on the Mac (TTS starved
/// of CPU or memory). Gaps the device counts while the lead stayed positive point at transport or the device
/// instead. Each frame's acknowledgement time covers the endpoint's audit write and publication.
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
    private var firstSent: ContinuousClock.Instant?
    private var audio: Duration = .zero
    private var minimumLead: Duration?
    private var acknowledgements: [Duration] = []

    package init(startedAt started: ContinuousClock.Instant) { self.started = started }

    /// A frame of `audio` was sent at `sentAt` and acknowledged `acknowledgedAfter` later.
    package mutating func sent(
        audio frameAudio: Duration, at sentAt: ContinuousClock.Instant, acknowledgedAfter acknowledgement: Duration
    ) {
        if let firstSent {
            let lead = audio - (sentAt - firstSent)
            minimumLead = min(minimumLead ?? lead, lead)
        } else {
            firstSent = sentAt
        }
        audio += frameAudio
        acknowledgements.append(acknowledgement)
    }

    package func summary(at end: ContinuousClock.Instant) -> Summary {
        let sorted = acknowledgements.sorted()
        let p95 = sorted.isEmpty ? Duration.zero : sorted[min(sorted.count - 1, (sorted.count * 95 + 99) / 100 - 1)]
        return Summary(
            frames: acknowledgements.count, audio: audio, firstAudio: firstSent.map { $0 - started },
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

    /// Logs the summary to the unified log (`log show --predicate 'category == "reply-timing"'`).
    package func log(outcome: String, at end: ContinuousClock.Instant = .now) {
        let line = timing.withLock { $0.summary(at: end).line }
        timingLogger.notice("\(line, privacy: .public) outcome=\(outcome, privacy: .public)")
    }
}
