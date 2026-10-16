import Foundation
import HailCore
import HailDaemonKit
import HailProtocol

/// One owned PCM-only renderer. Cleanup returns only after child ownership is settled, including failures.
@MainActor protocol CoachingSpeechSource: AnyObject {
    func consume(_ receive: (Data) throws -> Void) async throws
    func finish() async throws
    func cancel()
    func cleanup(cancel: Bool) async throws
}

protocol CoachingRendererJoining: Sendable {
    func requireSuccessfulExit() async throws
    func retire(cancel: Bool)
    func waitForCleanup() async throws
    func waitForCancellationSignals() async
}
extension OwnedReplyRenderer: CoachingRendererJoining {}

enum CoachingRendererCleanup {
    static func join(_ renderer: any CoachingRendererJoining, cancel: Bool) async throws {
        renderer.retire(cancel: cancel)
        // Deferred artifact retirement and signal submission are NOT an exact-child join.
        // This existing boundary waits for owned exit even when its eventual outcome is cancellation/error.
        _ = try? await renderer.requireSuccessfulExit()
        do { try await renderer.waitForCleanup() } catch {
            await renderer.waitForCancellationSignals()
            throw error
        }
        await renderer.waitForCancellationSignals()
    }
}

/// Existing renderer only; no reply publication, player, socket or route selection.
@MainActor final class LocalCoachingSpeechSource: CoachingSpeechSource {
    private let renderer: OwnedReplyRenderer
    init(text: String, outputRoot: URL, environment: [String: String]) throws {
        renderer = try OwnedReplyRenderer.startForJoinedRetirement(
            text: text, outputRoot: outputRoot, environment: environment)
    }
    init(renderer: OwnedReplyRenderer) { self.renderer = renderer }
    func consume(_ receive: (Data) throws -> Void) async throws {
        for try await data in renderer.audio { try receive(data) }
    }
    func finish() async throws { try await renderer.requireSuccessfulExit() }
    func cancel() { renderer.cancel() }
    func cleanup(cancel: Bool) async throws {
        try await CoachingRendererCleanup.join(renderer, cancel: cancel)
    }
}

/// Replaceable foreground TTS with no playback capability. Every effect passes the coordinator's original gate.
@MainActor final class CoachingSpeechRenderer: ForegroundCoachingSpeech {
    private final class Job {
        var source: (any CoachingSpeechSource)?
        var cancelled = false, timedOut = false
        var bytes = Data()
        var deadline = ContinuousClock.Instant.now
    }
    private let makeSource: (String) throws -> any CoachingSpeechSource
    private let clock: CoachingClock
    private var current: Job?

    init(clock: CoachingClock = .init(), source: @escaping (String) throws -> any CoachingSpeechSource) {
        self.clock = clock; makeSource = source
    }

    static func local(outputRoot: URL, environment: [String: String]) -> CoachingSpeechRenderer {
        CoachingSpeechRenderer { text in
            try LocalCoachingSpeechSource(text: text, outputRoot: outputRoot, environment: environment)
        }
    }
    isolated deinit { current?.source?.cancel() }
    func cancel() { current?.cancelled = true; current?.source?.cancel() }

    func render(_ text: String, emit: @escaping @MainActor (AudioPayload) throws -> Void) async throws {
        guard current == nil else { throw ForegroundCoachingError.busy }
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              text.unicodeScalars.count <= 280, text.unicodeScalars.allSatisfy(Self.printable),
              text.split(whereSeparator: { $0.isWhitespace }).count <= 45 else {
            throw ForegroundCoachingError.invalidSpeech
        }
        try Task.checkCancellation()
        let job = Job(); current = job
        job.deadline = clock.now().advanced(by: CoachingSpeechBudget.render)
        let cancelTimeout = clock.schedule(CoachingSpeechBudget.render) { [weak self, weak job] in
            guard let self, let job, self.current === job else { return }
            job.timedOut = true; job.source?.cancel()
        }
        defer { if current === job { current = nil }; cancelTimeout() }
        do {
            try check(job)
            let source = try makeSource(text); job.source = source
            try check(job)
            try await source.consume { data in try accept(data, job: job) }
            try check(job)
            guard !job.bytes.isEmpty, job.bytes.count.isMultiple(of: 2) else {
                throw CoachingSpeechFailure.invalidPCM
            }
            try await source.finish()
            try check(job)
            try await source.cleanup(cancel: false)
            try check(job)
            try deliver(job, emit: emit)
        } catch {
            let initiating: any Error = job.timedOut ? CoachingSpeechFailure.renderTimedOut : error
            job.cancelled = true; job.source?.cancel()
            // Join even on failure, retaining the initiating fixed failure if artifact cleanup also fails.
            do { try await job.source?.cleanup(cancel: true) } catch { /* Child join remains owned above. */ }
            throw initiating
        }
    }

    private static func printable(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .control, .format, .surrogate, .lineSeparator, .paragraphSeparator, .unassigned: false
        case .spaceSeparator: scalar.value == 32
        default: true
        }
    }

    private func check(_ job: Job) throws {
        if job.timedOut { throw CoachingSpeechFailure.renderTimedOut }
        try Task.checkCancellation()
        guard current === job, !job.cancelled else { throw CancellationError() }
        let now = clock.now()
        guard current === job, !job.cancelled else { throw CancellationError() }
        guard now < job.deadline else { throw CoachingSpeechFailure.renderTimedOut }
    }

    private func accept(_ data: Data, job: Job) throws {
        try check(job)
        guard !data.isEmpty else { throw CoachingSpeechFailure.invalidPCM }
        guard data.count <= CoachingSpeechBudget.pcmBytes - job.bytes.count else {
            throw CoachingSpeechFailure.durationExceeded
        }
        job.bytes.append(data)
    }

    private func deliver(_ job: Job, emit: (AudioPayload) throws -> Void) throws {
        var remaining = job.bytes, sequence = 0
        while !remaining.isEmpty {
            try check(job)
            let chunk = Data(remaining.prefix(48_000)); remaining.removeFirst(chunk.count)
            try emit(AudioPayload(codec: .pcm16, sampleRate: 24_000, channels: 1,
                                  sequence: sequence, isFinal: remaining.isEmpty, bytes: chunk))
            sequence += 1
            try check(job)
        }
    }
}
