import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit
import HailTestSupport

/// Invented input and PCM only. No terminal, process, device or provider endpoint is accessed.
actor RecipientContextAdapter: ProviderContextDelivering, ProviderReplyBindingLeasing {
    nonisolated let kind = "recipient"
    private var targets = [
        AdapterTarget(name: "reply", binding: "reply-binding"),
        AdapterTarget(name: "other", binding: "other-binding")
    ]
    private var authorities: [String: ReplyPublicationAuthority] = [:]
    private(set) var contexts: [ProviderTurnContext] = []
    private(set) var legacy: [String] = []
    private var held = false
    private var failure: (any Error)?
    private var entered = false
    private var arrivals: [UUID: CheckedContinuation<String?, Never>] = [:]
    private var release: CheckedContinuation<Void, Never>?
    var handoffWaiterCount: Int { arrivals.count }

    func listTargets() async throws -> [AdapterTarget] { targets }
    func capture(_ target: String) async throws -> String { "" }
    func deliver(_ text: String, to target: String, binding: String?) async throws { legacy.append(text) }
    func deliver(_ text: String, to target: String, binding: String, context: ProviderTurnContext) async throws {
        guard targets.contains(where: { $0.name == target && $0.binding == binding }) else {
            throw AdapterError.rebound(target)
        }
        contexts.append(context)
        if held {
            entered = true
            let waiters = Array(arrivals.values)
            arrivals.removeAll()
            for waiter in waiters { waiter.resume(returning: nil) }
            await withCheckedContinuation { release = $0 }
        }
        if let failure { throw failure }
    }
    func acquireReplyBindingLease(_ binding: ProviderSessionBinding) async throws -> ProviderReplyBindingLease {
        guard targets.contains(where: {
            Registry.id(kind: kind, name: $0.name) == binding.targetID && $0.binding == binding.sessionID && $0.alive
        }) else { throw AdapterError.rebound(binding.targetID) }
        let authority = authorities[binding.targetID] ?? ReplyPublicationAuthority()
        authorities[binding.targetID] = authority
        return ProviderReplyBindingLease(binding: binding, permit: authority.issuePermit())
    }
    func setTargets(_ targets: [AdapterTarget]) {
        for authority in authorities.values { authority.invalidate() }
        self.targets = targets
    }
    /// Every later handoff fails after it is recorded; `error` lets a test name the refusal (#894).
    func failHandoff(with error: any Error = ProviderCoordinatorSyntheticError.arbitraryFailure) { failure = error }
    /// Later handoffs succeed again (#894: the target's input was cleared).
    func passHandoff() { failure = nil }
    func holdHandoff() { held = true; entered = false }
    /// #896: neither a missing dispatch nor task cancellation may strand the test's lane.
    func waitForHandoff(within: Duration = .seconds(20)) async {
        if entered { return }
        let id = UUID()
        let timer = Task {
            do { try await Task.sleep(for: within) } catch { return }
            finishHandoffWait(id, failure: "timed out after \(within)")
        }
        defer { timer.cancel() }
        let failure: String? = await withTaskCancellationHandler {
            // Registration and this check share the actor turn; an earlier cancellation cannot be lost.
            if Task.isCancelled { return "cancelled before handoff" }
            return await withCheckedContinuation { arrivals[id] = $0 }
        } onCancel: {
            Task { await self.finishHandoffWait(id, failure: "cancelled before handoff") }
        }
        // Record on the waiting task so the issue belongs to its test, including cancellation's actor hop.
        if let failure { Issue.record("#896: waitForHandoff \(failure)") }
    }
    private func finishHandoffWait(_ id: UUID, failure: String) {
        // Arrival, timeout and cancellation all remove before resuming; other waiters keep their own slot.
        arrivals.removeValue(forKey: id)?.resume(returning: failure)
    }
    func releaseHandoff() {
        held = false
        release?.resume()
        release = nil
    }
}

// Direct admission tests use a synthetic synchronous enqueue, never a production authorization Boolean.
extension HostSession {
    func acceptsHostReply(_ frame: Frame) -> Bool { enqueueHostReply(frame, enqueue: { true }) }
}

final class RecipientTestClock: Sendable {
    private let value = Mutex<Int64>(1_700_000_000_000)
    private let origin = ContinuousClock.now
    private let elapsed = Mutex<Int64>(0)
    func now() -> Int64 { value.withLock { $0 } }
    func instant() -> ContinuousClock.Instant { origin.advanced(by: .milliseconds(elapsed.withLock { $0 })) }
    func advance(_ milliseconds: Int64) {
        value.withLock { $0 += milliseconds }
        elapsed.withLock { $0 += milliseconds }
    }
    func adjustWallClock(_ milliseconds: Int64) { value.withLock { $0 += milliseconds } }
}

struct RecipientTestRig {
    let host: HailHost
    let adapter: RecipientContextAdapter
    let clock = RecipientTestClock()
    static let target = "recipient:reply"

    static func make() async throws -> Self {
        _ = StallWatchdog.started // #704: names what stalls the pool, on CI only
        let adapter = RecipientContextAdapter()
        let registry = Registry()
        try await registry.register(adapter)
        // Recipient authority is tested here; default guard matching has its own suites.
        // One authored guard reduces unrelated wall-budget exposure in parallel lifecycle tests.
        var policy = Policy(guardPatterns: [.init(name: "synthetic guard", regex: "^synthetic guarded command$")],
                            deliveriesPerMinute: 1_000)
        try policy.allow(target, binding: "reply-binding", tier: .open)
        try policy.allow("recipient:other", binding: "other-binding", tier: .open)
        return Self(host: try HailHost(registry: registry, store: InMemoryPolicyStore(policy)), adapter: adapter)
    }

    func session(providerTurnEndsReported: Bool = false) async -> HostSession {
        let session = HostSession(
            host: host, authorizer: PersonalTerminalAuthorizer(), hostName: "mac-test", now: clock.now,
            requestClock: clock.instant, providerTurnEndsReported: providerTurnEndsReported
        )
        _ = await session.receive(helloFrame())
        _ = await session.receive(sessionFrame(payload: .control(.select(targetID: Self.target))))
        return session
    }

    func submit(on session: HostSession) async throws -> ProviderTurnContext {
        let before = await adapter.contexts.count
        let frame = sessionFrame(target: Self.target, payload: .text(TextPayload(text: "synthetic input")))
        let result = await session.receive(frame)
        try #require(result.frames.isEmpty)
        let contexts = await adapter.contexts
        try #require(contexts.count == before + 1)
        return try #require(contexts.last)
    }
}

func recipientDescriptor(_ context: ProviderTurnContext, audio: Bool = false) -> ReplyDescriptor {
    ReplyDescriptor(
        id: UUID(), hostID: "mac-test", targetID: RecipientTestRig.target,
        audioStreamID: audio ? UUID() : nil, requestID: context.id
    )
}

func recipientText(_ descriptor: ReplyDescriptor) -> Frame {
    Frame(timestamp: 1, target: descriptor.targetID, source: descriptor.hostID,
          payload: .text(TextPayload(text: "synthetic response", reply: descriptor)))
}

func recipientAudio(_ descriptor: ReplyDescriptor, sequence: Int, final: Bool = false) -> Frame {
    Frame(timestamp: 1, target: descriptor.targetID, source: descriptor.hostID, payload: .audio(AudioPayload(
        codec: .pcm16, sampleRate: 24_000, channels: 1, sequence: sequence,
        streamID: descriptor.audioStreamID, isFinal: final, bytes: Data([0, 0]), reply: descriptor
    )))
}
