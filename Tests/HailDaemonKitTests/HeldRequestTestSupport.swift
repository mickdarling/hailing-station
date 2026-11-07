import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

struct HeldTestRig: Sendable {
    let host: HailHost
    let adapter: RecipientContextAdapter
    let session: HostSession
    let clock: RecipientTestClock
    let privacy: HeldTestPrivacy
    let store: InMemoryPolicyStore

    static func make(tier: Tier = .open, limit: Int = 100) async throws -> Self {
        let clock = RecipientTestClock()
        let privacy = HeldTestPrivacy()
        let adapter = RecipientContextAdapter()
        let registry = Registry()
        try await registry.register(adapter)
        var policy = Policy(guardPatterns: [.init(name: "private rule", regex: "HELD_TOKEN")],
                            deliveriesPerMinute: limit)
        try policy.allow(RecipientTestRig.target, binding: "reply-binding", tier: tier)
        try policy.allow("recipient:other", binding: "other-binding", tier: .open)
        let store = InMemoryPolicyStore(policy)
        let host = try HailHost(registry: registry, store: store, requestNow: clock.instant)
        let session = HostSession(host: host, authorizer: PersonalTerminalAuthorizer(), requestClock: clock.instant,
                                  modeSnapshot: { _ in [.duckMode(on: privacy.withLock { $0 })] })
        _ = await session.receive(helloFrame())
        _ = await session.receive(sessionFrame(payload: .control(.select(targetID: RecipientTestRig.target))))
        return Self(host: host, adapter: adapter, session: session, clock: clock, privacy: privacy, store: store)
    }

    func dispatch(_ text: String = "HELD_TOKEN", reference: UUID? = nil) async throws -> LocalDispatchResult {
        try await HostSession.$ambientInputDispatch.withValue(true) {
            try await HostSession.$ambientReplyReference.withValue(reference) {
                try await session.dispatchResult(dispatchRequest(connection: await session.connectionID, text: text))
            }
        }
    }

    func hold(_ text: String = "HELD_TOKEN", reference: UUID? = nil) async throws -> HeldRequestEntry {
        guard case .held(let notice) = try await dispatch(text, reference: reference) else {
            throw HeldTestError.expectedHold
        }
        return try #require(await host.heldRequests.entries[notice.held])
    }

    func send(_ id: UUID) async -> HeldSendResult { await session.sendHeld(id, from: session.connectionID) }
    func discard(_ id: UUID) async -> HeldSendResult { await session.discardHeld(id, from: session.connectionID) }
    func select(_ target: String) async {
        _ = await session.receive(sessionFrame(payload: .control(.select(targetID: target))))
    }
}

enum HeldTestError: Error { case expectedHold }

final class HeldTestPrivacy: Sendable {
    private let state = Mutex(false)
    func withLock<Result>(_ body: (inout Bool) -> Result) -> Result { state.withLock(body) }
}
