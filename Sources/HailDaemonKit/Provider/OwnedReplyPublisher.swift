#if os(macOS)
public import Foundation
import Synchronization

// Admission, cancellation and retained ownership share one synchronized lifecycle boundary.
// swiftlint:disable file_length

public enum OwnedReplyPublisherError: Error, Sendable, Equatable {
    case invalidConfiguration, capacityExceeded, stopped, cancelled, deadline, startupFailed
    case commandFailed, ownershipLost, cleanupFailed
}

/// Aggregate resource/outcome counts only. Success is CLI acknowledgement, not physical hearing.
public struct OwnedReplyPublisherDiagnostics: Sendable {
    public var queued = 0
    public var retained = 0
    public var running = 0
    public var completed = 0
    public var failed = 0
    public var lastCleanupFailure: OwnedReplyPublisherError?
    public var lastFailure: OwnedReplyPublisherError?
}

/// One final reply a reply-owning adapter publishes for its own target and exact request. Text is spoken and shown
/// as-is, so it is bounded, carries no control (C0/C1) characters other than newline and tab, and passes the
/// inbound sanitizer's hidden-character rule (format, default-ignorable, variation-selector smuggling, fillers,
/// braille blank, noncharacters), including its narrow emoji exceptions such as ZWJ sequences.
public struct OwnedReply: Sendable, Equatable {
    /// Spoken replies stream as PCM under the reply endpoint's 120-frame budget (about 146 s of speech for one job,
    /// shared per minute across jobs). This bound keeps one reply's speech well inside it (roughly 80-90 s at
    /// typical rates), so an admitted reply is publishable whole. Adapters shorten longer answers before publishing.
    public static let maxSpokenBytes = 1_200
    public let requestID: UUID
    public let hostID: String
    public let targetID: String
    public let text: String

    public init(requestID: UUID, hostID: String, targetID: String, text: String) throws {
        guard Self.isSafeTarget(targetID),
              text.contains(where: { !$0.isWhitespace }), text.utf8.count <= Self.maxSpokenBytes,
              !Self.hasHidden(text, allowing: [9, 10]) else { throw OwnedReplyPublisherError.invalidConfiguration }
        self.requestID = requestID; self.hostID = hostID; self.targetID = targetID; self.text = text
    }

    static func isSafeTarget(_ target: String) -> Bool {
        !target.isEmpty && target.utf8.count <= 256 && !hasHidden(target, allowing: [])
    }

    private static func hasHidden(_ value: String, allowing allowed: Set<UInt32>) -> Bool {
        value.unicodeScalars.contains {
            !allowed.contains($0.value) && $0.properties.generalCategory == .control
        } || Sanitizer.firstHiddenCharacterClass(in: value) != nil
    }
}

struct OwnedReplyPublisherConfiguration: Sendable {
    let executable: URL
    let socket: URL
    let root: URL
    let hostID: String
    let environment: [String: String]
    let deadline: Duration
    var targets: Set<String> = [DiagnosticReplyBridgeAdapter.targetID]
    var hooks = OwnedReplyGroupHooks()
}

private struct ReplyPublisherEntry {
    let reply: OwnedReply
    var continuation: CheckedContinuation<Void, any Error>?
    var starting = false
    var cancelled = false
    var job: OwnedReplyGroupJob?
    var retainedDirectory: OwnedReplyJobDirectory?
    var deadline: (any DispatchSourceTimer)?
}

private struct ReplyPublisherState {
    var stopped = false
    var entries: [UUID: ReplyPublisherEntry] = [:]
    var queued: [UUID] = []
    var status = OwnedReplyPublisherDiagnostics()
}

/// Default-off, unregistered controlled diagnostic publisher. No client selects executable/env/cwd.
/// Cleanup ownership survives caller retirement and continues occupying bounded admission slots.
public final class OwnedReplyPublisher: Sendable {
    public static let capacity = 16
    public static let concurrency = 4
    private let configuration: OwnedReplyPublisherConfiguration
    private let state = Mutex(ReplyPublisherState())

    /// `targets` are the reply-owning targets this publisher may speak for; the default is the diagnostic bridge.
    /// `deadline` bounds admission to outcome (queue wait, render and publication), not directory cleanup, which
    /// is retained and reported separately. The 30-second default suits the short diagnostic phrase; adapters
    /// publishing spoken provider answers pass a longer bound, at most five minutes. Use one publisher per adapter:
    /// its 4 slots are shared, so a long-deadline target must not share an instance with the diagnostic target.
    public convenience init(executable: URL, socket: URL, outputRoot: URL, hostID: String,
                            targets: Set<String> = [DiagnosticReplyBridgeAdapter.targetID],
                            deadline: Duration = .seconds(30)) throws {
        guard !targets.isEmpty, targets.allSatisfy(OwnedReply.isSafeTarget), deadline <= .seconds(300) else {
            throw OwnedReplyPublisherError.invalidConfiguration
        }
        try self.init(configuration: OwnedReplyPublisherConfiguration(
            executable: executable, socket: socket, root: outputRoot, hostID: hostID,
            environment: ProcessInfo.processInfo.environment, deadline: deadline, targets: targets))
    }

    // Internal local fixture seam, never exposed through mobile or daemon configuration.
    init(configuration: OwnedReplyPublisherConfiguration) throws {
        guard configuration.executable.isFileURL, configuration.socket.isFileURL,
              !configuration.hostID.isEmpty, configuration.hostID.utf8.count <= 256,
              configuration.deadline > .zero,
              !configuration.hostID.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }) else {
            throw OwnedReplyPublisherError.invalidConfiguration
        }
        do { try OwnedReplyRenderer.validateOutputRoot(configuration.root) } catch {
            throw OwnedReplyPublisherError.invalidConfiguration
        }
        self.configuration = configuration
    }

    /// Publishes one reply for a target this publisher was configured to own; any other target is refused.
    public func publish(_ reply: OwnedReply) async throws {
        let admission = UUID()
        try await withTaskCancellationHandler {
            try Task.checkCancellation()
            try await withCheckedThrowingContinuation { continuation in
                let failure = state.withLock { current -> OwnedReplyPublisherError? in
                    guard !current.stopped else { return .stopped }
                    guard reply.hostID == configuration.hostID, configuration.targets.contains(reply.targetID) else {
                        return .invalidConfiguration
                    }
                    guard current.entries.count < Self.capacity else { return .capacityExceeded }
                    current.entries[admission] = ReplyPublisherEntry(reply: reply, continuation: continuation)
                    current.queued.append(admission)
                    return nil
                }
                if let failure { continuation.resume(throwing: failure) } else {
                    // Closes cancellation before continuation/admission installation, without an orphan task.
                    if Task.isCancelled { cancel(admission) }
                    armDeadline(admission)
                    pump()
                }
            }
        } onCancel: { self.cancel(admission) }
    }

    private func pump() {
        let starts = state.withLock { current -> [(UUID, OwnedReply)] in
            var starts: [(UUID, OwnedReply)] = []
            var occupied = current.entries.values.filter { $0.starting || $0.job != nil }.count
            while !current.stopped, occupied < Self.concurrency, !current.queued.isEmpty {
                let id = current.queued.removeFirst()
                guard var entry = current.entries[id] else { continue }
                entry.starting = true; current.entries[id] = entry
                starts.append((id, entry.reply)); occupied += 1
            }
            return starts
        }
        for (id, reply) in starts {
            DispatchQueue.global(qos: .utility).async { self.start(id, reply: reply) }
        }
    }

    private func start(_ id: UUID, reply: OwnedReply) {
        do {
            let job = try OwnedReplyGroupJob(configuration: configuration, reply: reply,
                                            cancelled: { self.cancelled(id) },
                                            outcome: { self.outcome(id, $0) }, cleanup: .init(
                                                cleaned: { self.cleaned(id) },
                                                failed: { self.recordCleanupFailure($0) }))
            configuration.hooks.beforeInstall()
            let cancel = state.withLock { current -> Bool in
                guard var entry = current.entries[id] else { return true }
                entry.starting = false; entry.job = job; current.entries[id] = entry
                return entry.cancelled || current.stopped
            }
            job.activate(cancelled: cancel)
        } catch {
            if let retention = error as? ReplyJobStartupRetention {
                state.withLock { current in
                    current.entries[id]?.retainedDirectory = retention.directory
                    current.status.lastCleanupFailure = .cleanupFailed
                }
                outcome(id, .failure(.cleanupFailed))
                return // Unknown directory identity/removal never releases the resource admission.
            }
            outcome(id, .failure((error as? OwnedReplyPublisherError) ?? .startupFailed))
            cleaned(id)
        }
    }

    private func cancelled(_ id: UUID) -> Bool {
        state.withLock { $0.stopped || $0.entries[id]?.cancelled != false }
    }

    private func outcome(_ id: UUID, _ result: Result<Void, OwnedReplyPublisherError>) {
        let done = state.withLock { current -> CheckedContinuation<Void, any Error>? in
            guard var entry = current.entries[id], let continuation = entry.continuation else { return nil }
            entry.deadline?.setEventHandler {}; entry.deadline?.cancel(); entry.deadline = nil
            entry.continuation = nil; current.entries[id] = entry
            switch result {
            case .success: current.status.completed = min(current.status.completed, Int.max - 1) + 1
            case .failure(let failure):
                current.status.failed = min(current.status.failed, Int.max - 1) + 1
                current.status.lastFailure = failure
            }
            return continuation
        }
        done?.resume(with: result.mapError { $0 as any Error })
    }

    private func cleaned(_ id: UUID) {
        _ = state.withLock { $0.entries.removeValue(forKey: id) }
        pump()
    }

    private func cancel(_ id: UUID, failure: OwnedReplyPublisherError = .cancelled) {
        let job = state.withLock { current -> OwnedReplyGroupJob? in
            guard var entry = current.entries[id] else { return nil }
            entry.cancelled = true; current.entries[id] = entry
            return entry.job
        }
        if let job { job.cancel(failure) } else {
            configuration.hooks.afterCancellationLatch()
            outcome(id, .failure(failure))
            let queued = state.withLock { current -> Bool in
                // Startup may have installed a job since cancellation latched. That job sees the
                // latch during activation and retains its admission until cleanup succeeds.
                guard let entry = current.entries[id], !entry.starting, entry.job == nil else { return false }
                current.queued.removeAll { $0 == id }; current.entries.removeValue(forKey: id)
                return true
            }
            if queued { pump() }
        }
    }

    public func stop() {
        let ids = state.withLock { current -> [UUID] in
            current.stopped = true
            return Array(current.entries.keys)
        }
        for id in ids { cancel(id) }
    }

    // Internal fixed-category lifecycle event, not a client diagnostic/configuration operation.
    func recordCleanupFailure(_ failure: OwnedReplyPublisherError) {
        state.withLock { $0.status.lastCleanupFailure = failure }
    }

    public func diagnostics() -> OwnedReplyPublisherDiagnostics {
        state.withLock { current in
            var value = current.status
            value.queued = current.queued.count
            value.retained = current.entries.count - value.queued
            value.running = current.entries.values.filter { $0.starting || $0.job != nil }.count
            return value
        }
    }
}

extension OwnedReplyPublisher {
    /// The diagnostic bridge's fixed phrase, published as a generic owned reply for its own target.
    public func publish(_ reply: DiagnosticBridgeReply) async throws {
        guard reply.sequence > 0 else { throw OwnedReplyPublisherError.invalidConfiguration }
        try await publish(try reply.owned)
    }

    private func armDeadline(_ id: UUID) {
        let timer = DispatchSource.makeTimerSource(queue: .global(qos: .utility))
        timer.setEventHandler { self.cancel(id, failure: .deadline) }
        let seconds = Double(configuration.deadline.components.seconds)
        let fraction = Double(configuration.deadline.components.attoseconds) / 1e18
        timer.schedule(deadline: .now() + seconds + fraction)
        timer.activate()
        let retained = state.withLock { current -> Bool in
            guard current.entries[id]?.continuation != nil else { return false }
            current.entries[id]?.deadline = timer
            return true
        }
        if !retained { timer.setEventHandler {}; timer.cancel() }
    }
}
#endif
