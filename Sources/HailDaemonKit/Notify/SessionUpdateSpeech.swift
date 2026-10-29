#if os(macOS)
public import Foundation
import Synchronization

/// Existing host-owned house speech only. Implementations publish bounded 24 kHz mono PCM sequentially and
/// join retirement before returning. No implementation plays audio locally or chooses a device.
public protocol SessionUpdateSpeechRendering: Sendable {
    func render(_ text: String, publish: @Sendable (Data, Bool) async throws -> Void) async throws
}

public enum SessionUpdateSpeechError: Error, Sendable { case invalidAudio, publicationRefused }

/// Inert until a connected update with the separate audio capability has been admitted. Uses the same owned
/// vbsay renderer as ordinary replies; no second synthesizer, private credentials, or service installation.
public struct OwnedSessionUpdateSpeechRenderer: SessionUpdateSpeechRendering {
    private let outputRoot: URL
    private let environment: [String: String]

    public init(outputRoot: URL) throws {
        try OwnedReplyRenderer.validateOutputRoot(outputRoot)
        self.outputRoot = outputRoot
        environment = ProcessInfo.processInfo.environment
    }

    public func render(_ text: String, publish: @Sendable (Data, Bool) async throws -> Void) async throws {
        try Task.checkCancellation()
        let renderer = try OwnedReplyRenderer.startForJoinedRetirement(
            text: text, outputRoot: outputRoot, environment: environment)
        do {
            try await withTaskCancellationHandler {
                try await consume(renderer, publish: publish)
            } onCancel: { renderer.cancel() }
            try await cleanup(renderer, cancel: false)
        } catch {
            renderer.cancel()
            try await cleanup(renderer, cancel: true)
            throw error
        }
    }

    private func consume(
        _ renderer: OwnedReplyRenderer, publish: @Sendable (Data, Bool) async throws -> Void
    ) async throws {
        let pacing = ReplyStreamPacing()
        var pending = Data(), total = 0
        for try await bytes in renderer.audio {
            try Task.checkCancellation()
            guard bytes.count <= 60 * 48_000 - total else { throw SessionUpdateSpeechError.invalidAudio }
            total += bytes.count
            pending.append(bytes)
            while pending.count > 24_000 {
                let chunk = Data(pending.prefix(24_000))
                try await pacing.admit(audio: 0.5)
                try await publish(chunk, false)
                pending.removeFirst(24_000)
            }
        }
        try await renderer.requireSuccessfulExit()
        guard total > 0, pending.count.isMultiple(of: 2) else { throw SessionUpdateSpeechError.invalidAudio }
        try await pacing.admit(audio: ReplyStreamPacer.seconds(pcm16Bytes: pending.count, sampleRate: 24_000))
        try await publish(pending, true)
    }

    private func cleanup(_ renderer: OwnedReplyRenderer, cancel: Bool) async throws {
        renderer.retire(cancel: cancel)
        // Deferred artifact cleanup and submitted signals are not a child join.
        _ = try? await renderer.requireSuccessfulExit()
        do { try await renderer.waitForCleanup() } catch {
            await renderer.waitForCancellationSignals()
            throw error
        }
        await renderer.waitForCancellationSignals()
    }
}
/// Listener lifetime and quiet changes participate in the final synchronous enqueue after asynchronous policy
/// lookup. This gate never waits for the transport completion.
final class SessionUpdateFence: Sendable {
    private struct State {
        var allowed = true
        var renderer: (any SessionUpdateSpeechRendering)?
        var speechID: UUID?
        var speech: Task<Void, Never>?
        var speechTaskID: UUID?
        var speechPrivacyRevision: UInt64?
        var receipts: [SessionUpdateCancellationReceipt] = []
        var onIdle: (@Sendable () async -> Void)?
    }
    private let state = Mutex(State())
    func close() {
        let task = state.withLock { value in value.allowed = false; return value.speech }
        task?.cancel()
    }
    func quiet() { close() }
    func enqueue(_ operation: () -> Bool) -> Bool { state.withLock { $0.allowed && operation() } }
    func configure(_ renderer: any SessionUpdateSpeechRendering, onIdle: (@Sendable () async -> Void)? = nil) {
        state.withLock { $0.renderer = renderer; $0.onIdle = onIdle }
    }
    var speechStatus: String {
        state.withLock {
            guard $0.renderer != nil else { return "not_configured" }
            return $0.receipts.count >= 128 ? "receipt_capacity" : "device_attention_gated"
        }
    }
    var speechBusy: Bool { state.withLock { $0.speechID != nil } }

    /// Keep delivered-but-buffered identities after renderer completion. At capacity, decline new speech rather
    /// than forget an identity that a device could still have queued. Cancellations carry no original words.
    func remember(_ receipt: SessionUpdateCancellationReceipt) -> Bool {
        state.withLock { value in
            guard value.allowed else { return false }
            if !value.receipts.contains(where: { $0.update == receipt.update && $0.connection == receipt.connection }) {
                guard value.receipts.count < 128 else { return false }
                value.receipts.append(receipt)
            }
            value.speechPrivacyRevision = receipt.privacyRevision
            return true
        }
    }

    func cancelProactive(olderThan revision: UInt64? = nil) -> [SessionUpdateCancellationReceipt] {
        let result = state.withLock { value -> ([SessionUpdateCancellationReceipt], Task<Void, Never>?) in
            let old: (SessionUpdateCancellationReceipt) -> Bool = {
                guard let revision else { return true }
                return $0.privacyRevision < revision
            }
            let receipts = value.receipts.filter(old)
            value.receipts.removeAll(where: old)
            let cancel = revision.map { boundary in value.speechPrivacyRevision.map { $0 < boundary } == true } ?? true
            return (receipts, cancel ? value.speech : nil)
        }
        result.1?.cancel()
        return result.0
    }

    /// A single owned renderer at a time. Busy updates still have their cards; no background model or render storm.
    func startSpeech(_ operation: @escaping @Sendable (any SessionUpdateSpeechRendering) async -> Void) {
        let id = UUID()
        let start = AsyncStream<Void>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let task = state.withLock { value -> Task<Void, Never>? in
            guard value.allowed, value.speechID == nil, let renderer = value.renderer else { return nil }
            value.speechID = id
            value.speechTaskID = id
            let task = Task {
                for await _ in start.stream {
                    if !Task.isCancelled { await operation(renderer) }
                    break
                }
                let idle = self.state.withLock { value -> (@Sendable () async -> Void)? in
                    guard value.speechID == id else { return nil }
                    value.speechID = nil; value.speechPrivacyRevision = nil
                    return value.onIdle
                }
                // The renderer operation has joined retirement. Observe availability outside the lock, after
                // clearing only this job's identity, including cancellation and failed publication paths.
                await idle?()
                self.state.withLock {
                    if $0.speechTaskID == id { $0.speech = nil; $0.speechTaskID = nil }
                }
            }
            value.speech = task
            return task
        }
        guard task != nil else { start.continuation.finish(); return }
        start.continuation.yield(())
        start.continuation.finish()
        // One programmatic deadline, not a poller. A quiet/stop or timeout cancels the retained exact-child job.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 90) { [weak self] in
            let pending = self?.state.withLock { $0.speechID == id ? $0.speech : nil }
            pending?.cancel()
        }
    }

    func joinSpeech() async { await state.withLock { $0.speech }?.value }
}

#endif
