import Foundation
import Testing
@testable import HailDaemonKit

/// #609 review of #629: holding is idempotent and refuses expired updates; ties and eviction follow drain order.
@Suite struct SessionUpdateHoldTests {
    let start = ContinuousClock().now
    let phone = UUID()

    func at(_ seconds: Double) -> SessionUpdate.Instant { start + .seconds(seconds) }

    func update(_ priority: SessionUpdatePriority = .info, _ spoken: String = "Done", at seconds: Double = 0) throws
        -> SessionUpdate {
        try #require(SessionUpdate(session: "Voice Work", priority: priority, spoken: spoken, submitted: at(seconds)))
    }

    func enabled(_ change: (inout SessionUpdatePolicy) -> Void = { _ in }) -> SessionUpdateQueue {
        var policy = SessionUpdatePolicy(enabled: true)
        change(&policy)
        return SessionUpdateQueue(policy: policy)
    }

    @Test func holdingTwicePushesOnce() throws {
        var queue = enabled()
        let action = try update(.action)
        let audience = SessionUpdateAudience(listeningDevice: phone)
        #expect(queue.hold(action, audience: audience, at: at(1)) == .held(push: phone))
        #expect(queue.hold(action, audience: audience, at: at(2)) == .held(push: nil), "already held: no second push")
        #expect(queue.held.count == 1)
    }

    @Test func anExpiredUpdateIsRefused() throws {
        var queue = enabled { $0.lifetime = .seconds(60) }
        let stale = try update(.action, at: 0)
        let audience = SessionUpdateAudience(listeningDevice: phone)
        #expect(queue.hold(stale, audience: audience, at: at(60)) == .refused(.expired))
        #expect(queue.held.isEmpty)
        #expect(queue.hold(stale, audience: audience, at: at(59)) == .held(push: phone))
    }

    @Test func equalSubmitTimesDrainInHoldOrder() throws {
        var queue = enabled()
        let first = try update(.info, "first", at: 5)
        let second = try update(.info, "second", at: 5)
        let third = try update(.info, "third", at: 5)
        for each in [second, first, third] { _ = queue.hold(each, audience: .init(), at: at(6)) }
        #expect(queue.drain(.asked, audience: .init(), now: at(7)).map(\.id) == [second.id, first.id, third.id])
    }

    @Test func aFullQueueEvictsTheOldestInfoBySubmitTime() throws {
        var queue = enabled { $0.capacity = 2 }
        let newer = try update(.info, "newer", at: 10)
        let older = try update(.info, "older", at: 1)
        _ = queue.hold(newer, audience: .init(), at: at(11))
        _ = queue.hold(older, audience: .init(), at: at(12)) // held later, submitted earlier
        let incoming = try update(.info, "incoming", at: 13)
        #expect(queue.hold(incoming, audience: .init(), at: at(13)) == .held(push: nil))
        #expect(Set(queue.held.map(\.id)) == [newer.id, incoming.id], "the oldest submitted went, not the first held")
    }
}
