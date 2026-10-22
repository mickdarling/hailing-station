import Foundation
import os
import Synchronization

private let timingLogger = Logger(
    subsystem: "com.mickdarling.hailing-station",
    category: ReplyTimingLog.category(executablePath: Bundle.main.executablePath)
)

/// Where reply timing is logged. `haild reply` writes these lines (run by a session's hook, or as the daemon's reply
/// child). An installed `haild` logs under `reply-timing`; one run from a SwiftPM `.build/` directory, as the CLI tests
/// and `swift run` do, logs under `reply-timing-dev`, so a test run never reads as live replies (#737). The path is
/// not resolved: an installed `haild` reached through `~/.local/bin` still reads as installed.
package enum ReplyTimingLog {
    package static func category(executablePath: String?) -> String {
        executablePath?.contains("/.build/") == true ? "reply-timing-dev" : "reply-timing"
    }
}

/// One spoken reply's delivery timing (#737), so choppy playback shows in data. The device plays a reply from its
/// first frame with no reserve, so when a frame is acknowledged its queue holds the audio acknowledged before it less
/// the time since the first frame was: the lead. Below about -100 ms (the device's lead-in silence) the device very
/// likely ran dry because the Mac fell behind real time (TTS starved of CPU or memory), unless it was still playing
/// an earlier reply or was paused, which hold a reply back. Gaps the device counts while the lead stayed positive
/// point at transport or the device instead. A frame's acknowledgement time covers the endpoint's audit write and
/// publication, and any resend waits after a `rate limited` or `requestPending` refusal, which it counts.
package struct ReplyStreamTiming: Sendable, Equatable {
    package struct Summary: Sendable, Equatable {
        package var frames = 0
        package var audio: Duration = .zero
        package var firstAudio: Duration?
        package var minimumLead: Duration?
        package var slowestAcknowledgement: Duration = .zero
        package var acknowledgementP95: Duration = .zero
        /// Resend waits inside the audio frames' acknowledgement times.
        package var resends = 0
        package var wall: Duration = .zero
    }

    private let started: ContinuousClock.Instant
    private var firstAcknowledged: ContinuousClock.Instant?
    private var audio: Duration = .zero
    private var minimumLead: Duration?
    private var acknowledgements: [Duration] = []
    private var resends = 0

    package init(startedAt started: ContinuousClock.Instant) { self.started = started }

    /// A frame of `audio` was sent at `sentAt` and acknowledged `acknowledgedAfter` later, when the device has it,
    /// after `resends` waits on refusals.
    package mutating func sent(
        audio frameAudio: Duration, at sentAt: ContinuousClock.Instant, acknowledgedAfter acknowledgement: Duration,
        resends frameResends: Int = 0
    ) {
        resends += frameResends
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
            resends: resends, wall: end - started
        )
    }
}

extension ReplyStreamTiming.Summary {
    /// One log line, numbers only.
    package var line: String {
        func ms(_ value: Duration?) -> String { value.map { String(Int64($0 / .milliseconds(1))) } ?? "none" }
        return "reply audio: frames=\(frames) audio_ms=\(ms(audio)) first_audio_ms=\(ms(firstAudio)) "
            + "min_lead_ms=\(ms(minimumLead)) ack_max_ms=\(ms(slowestAcknowledgement)) "
            + "ack_p95_ms=\(ms(acknowledgementP95)) resends=\(resends) wall_ms=\(ms(wall))"
    }
}

/// A reply job's timing, shared by the frames it sends; logged once as the reply ends.
package final class ReplyTimingRecorder: Sendable {
    private let timing: Mutex<ReplyStreamTiming>

    package init(startedAt started: ContinuousClock.Instant = .now) {
        timing = Mutex(ReplyStreamTiming(startedAt: started))
    }

    package func sent(audio: Duration, at sentAt: ContinuousClock.Instant, acknowledgedAfter: Duration, resends: Int) {
        timing.withLock { $0.sent(audio: audio, at: sentAt, acknowledgedAfter: acknowledgedAfter, resends: resends) }
    }

    /// Logs the summary to the unified log (`log show --predicate 'category == "reply-timing"'`, or `reply-timing-dev`
    /// from a build; see `ReplyTimingLog`). `line` is built from numbers only, and `outcome` is one of a few fixed
    /// words, so both are public. A reply that sent its audio some other way (vbsay's file mode) measured nothing and
    /// says so.
    package func log(outcome: String, at end: ContinuousClock.Instant = .now) {
        let summary = timing.withLock { $0.summary(at: end) }
        let outcome = outcome == "played" && summary.frames == 0 ? "played_unmeasured" : outcome
        timingLogger.notice("\(summary.line, privacy: .public) outcome=\(outcome, privacy: .public)")
    }
}
