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

/// Existing renderer only; no reply publication, player, socket or route selection.
@MainActor private final class LocalCoachingSpeechSource: CoachingSpeechSource {
    private let renderer: OwnedReplyRenderer
    init(text: String, outputRoot: URL, environment: [String: String]) throws {
        renderer = try OwnedReplyRenderer(text: text, outputRoot: outputRoot, environment: environment)
    }
    func consume(_ receive: (Data) throws -> Void) async throws {
        for try await data in renderer.audio { try receive(data) }
    }
    func finish() async throws { try await renderer.requireSuccessfulExit() }
    func cancel() { renderer.cancel() }
    func cleanup(cancel: Bool) async throws {
        renderer.retire(cancel: cancel)
        // Even abnormal cleanup waits for owned reaping; failed artifacts remain intentionally preserved.
        do {
            try await renderer.waitForCleanup()
        } catch {
            await renderer.waitForCancellationSignals()
            throw error
        }
        await renderer.waitForCancellationSignals()
    }
}

/// Replaceable foreground TTS with no playback capability. Every effect passes the coordinator's original gate.
@MainActor final class CoachingSpeechRenderer: ForegroundCoachingSpeech {
    private final class Job {
        var source: (any CoachingSpeechSource)?
        var cancelled = false
        var bytes = 0, sequence = 0
        var tail = Data(), pending = Data()
    }
    private let makeSource: (String) throws -> any CoachingSpeechSource
    private var current: Job?

    init(source: @escaping (String) throws -> any CoachingSpeechSource) { makeSource = source }

    /// Inert factory. Construction/validation/spawn occur only when the explicitly enabled owner renders.
    static func local(outputRoot: URL, environment: [String: String]) -> CoachingSpeechRenderer {
        CoachingSpeechRenderer { text in
            try LocalCoachingSpeechSource(text: text, outputRoot: outputRoot, environment: environment)
        }
    }
    isolated deinit { current?.source?.cancel() }

    func cancel() { current?.cancelled = true; current?.source?.cancel() }

    func render(_ text: String, emit: @escaping @MainActor (AudioPayload) throws -> Void) async throws {
        guard current == nil else { throw ForegroundCoachingError.busy }
        guard !text.isEmpty, text.unicodeScalars.count <= 280, text.utf8.allSatisfy({ (32...126).contains($0) }),
              text.split(whereSeparator: { $0.isWhitespace }).count <= 45 else {
            throw ForegroundCoachingError.invalidSpeech
        }
        try Task.checkCancellation()
        let job = Job(); current = job
        defer { if current === job { current = nil } }
        do {
            let source = try makeSource(text); job.source = source
            try check(job)
            try await source.consume { data in try accept(data, job: job, emit: emit) }
            try check(job)
            guard job.tail.isEmpty, !job.pending.isEmpty else { throw ForegroundCoachingError.invalidSpeech }
            try await source.finish()
            try check(job)
            try await source.cleanup(cancel: false)
            try check(job)
            try deliver(job.pending, final: true, job: job, emit: emit)
        } catch {
            job.cancelled = true; job.source?.cancel()
            // Do not release the slot while a noncooperative source still owns its child or cleanup.
            try await job.source?.cleanup(cancel: true)
            throw error
        }
    }

    private func check(_ job: Job) throws {
        try Task.checkCancellation()
        guard current === job, !job.cancelled else { throw CancellationError() }
    }

    private func accept(_ data: Data, job: Job, emit: (AudioPayload) throws -> Void) throws {
        try check(job)
        guard !data.isEmpty, data.count <= 96_000 - job.bytes else {
            throw ForegroundCoachingError.invalidSpeech
        }
        job.bytes += data.count
        var bytes = job.tail + data; job.tail = Data()
        if !bytes.count.isMultiple(of: 2) { job.tail = Data(bytes.suffix(1)); bytes.removeLast() }
        while !bytes.isEmpty {
            let chunk = Data(bytes.prefix(48_000)); bytes.removeFirst(chunk.count)
            if !job.pending.isEmpty { try deliver(job.pending, final: false, job: job, emit: emit) }
            job.pending = chunk
        }
    }

    private func deliver(_ data: Data, final: Bool, job: Job, emit: (AudioPayload) throws -> Void) throws {
        try check(job)
        guard job.sequence < 32 else { throw ForegroundCoachingError.invalidSpeech }
        job.sequence += 1
        try emit(AudioPayload(codec: .pcm16, sampleRate: 24_000, channels: 1,
                              sequence: job.sequence, isFinal: final, bytes: data))
        try check(job) // The private gate may synchronously retire this owner.
    }
}
