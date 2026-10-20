import Foundation
import Testing
@testable import HailDaemonKit

@Suite struct SessionUpdateQueueTests {
    let start = ContinuousClock().now
    let phone = UUID()
    let pad = UUID()

    func at(_ seconds: Double) -> SessionUpdate.Instant { start + .seconds(seconds) }

    func update(
        _ priority: SessionUpdatePriority = .info, session: String = "Voice Work", spoken: String = "The deck is built",
        at seconds: Double = 0
    ) throws -> SessionUpdate {
        try #require(SessionUpdate(session: session, priority: priority, spoken: spoken, submitted: at(seconds)))
    }

    func enabled(_ change: (inout SessionUpdatePolicy) -> Void = { _ in }) -> SessionUpdateQueue {
        var policy = SessionUpdatePolicy(enabled: true)
        change(&policy)
        return SessionUpdateQueue(policy: policy)
    }

    @Test func offByDefault() throws {
        var queue = SessionUpdateQueue()
        #expect(queue.policy.enabled == false)
        let listening = SessionUpdateAudience(listeningDevice: phone)
        #expect(queue.submit(try update(.action), audience: listening, now: at(0)) == .refused(.disabled))
        #expect(queue.held.isEmpty)
    }

    @Test func targetIsTheListeningDeviceElseTheLastActive() {
        #expect(SessionUpdateAudience(listeningDevice: phone, lastActiveDevice: pad).target == phone)
        #expect(SessionUpdateAudience(lastActiveDevice: pad).target == pad)
        #expect(SessionUpdateAudience().target == nil)
    }

    @Test func infoIsAlwaysHeldWithoutAPush() throws {
        var queue = enabled()
        let listening = SessionUpdateAudience(listeningDevice: phone)
        #expect(queue.submit(try update(.info), audience: listening, now: at(0)) == .held(push: nil))
        #expect(queue.held.count == 1)
    }

    @Test func actionSpeaksNowOnlyWhenListeningAndNotQuietOrMedia() throws {
        var queue = enabled()
        let action = try update(.action)
        let listening = SessionUpdateAudience(listeningDevice: phone, lastActiveDevice: pad)
        #expect(queue.submit(action, audience: listening, now: at(0)) == .speak(action, device: phone))
        #expect(queue.held.isEmpty, "a spoken update is not held")

        var media = listening
        media.media = true
        #expect(queue.submit(try update(.action), audience: media, now: at(1)) == .held(push: phone))
        let idle = SessionUpdateAudience(lastActiveDevice: pad)
        #expect(queue.submit(try update(.action), audience: idle, now: at(2)) == .held(push: pad))
        #expect(queue.submit(try update(.action), audience: .init(), now: at(3)) == .held(push: nil))
        var quiet = listening
        quiet.quiet = true
        #expect(queue.submit(try update(.action), audience: quiet, now: at(4)) == .held(push: nil))
        #expect(queue.held.count == 4)
    }

    @Test func failedSpeechCanBeHeldWithoutSpendingBudget() throws {
        var queue = enabled { $0.perSessionLimit = 1 }
        let action = try update(.action)
        let listening = SessionUpdateAudience(listeningDevice: phone)
        #expect(queue.submit(action, audience: listening, now: at(0)) == .speak(action, device: phone))
        let first = queue.hold(action, audience: listening, at: at(1))
        let again = queue.hold(action, audience: listening, at: at(1))
        #expect(first == .held(push: phone) && again == .held(push: phone), "holding twice keeps one copy")
        #expect(queue.held.map(\.id) == [action.id])
        #expect(queue.retryAfter(session: "Voice Work", now: at(1)) == .seconds(3_599))
    }

    @Test func holdDecidesThePushFromTheAudienceNow() throws {
        var queue = enabled()
        let action = try update(.action)
        #expect(queue.hold(action, audience: .init(lastActiveDevice: pad), at: at(0)) == .held(push: pad))
        #expect(queue.hold(try update(.action), audience: .init(lastActiveDevice: pad, quiet: true), at: at(0))
                == .held(push: nil), "quiet holds without a push")
        #expect(queue.hold(try update(.info), audience: .init(listeningDevice: phone), at: at(0)) == .held(push: nil))
        #expect(queue.hold(try update(.action), audience: .init(), at: at(0)) == .held(push: nil))
        var off = SessionUpdateQueue()
        #expect(off.hold(action, audience: .init(listeningDevice: phone), at: at(0)) == .refused(.disabled))
    }

    @Test func aReheldActionKeepsItsSubmitOrder() throws {
        var queue = enabled()
        let early = try update(.action, spoken: "early", at: 0)
        let late = try update(.action, spoken: "late", at: 5)
        let listening = SessionUpdateAudience(listeningDevice: phone)
        #expect(queue.submit(early, audience: listening, now: at(0)) == .speak(early, device: phone))
        _ = queue.submit(late, audience: .init(), now: at(5))
        _ = queue.hold(early, audience: .init(), at: at(10))
        #expect(queue.drain(.asked, audience: .init(), now: at(11)).map(\.id) == [early.id, late.id])
    }

    @Test func eachSessionHasItsOwnSlidingBudget() throws {
        var queue = enabled { ($0.perSessionLimit, $0.window) = (2, .seconds(600)) }
        let audience = SessionUpdateAudience()
        #expect(queue.submit(try update(at: 0), audience: audience, now: at(0)) == .held(push: nil))
        #expect(queue.submit(try update(at: 100), audience: audience, now: at(100)) == .held(push: nil))
        #expect(queue.submit(try update(at: 200), audience: audience, now: at(200))
                == .refused(.rateLimited(retryAfter: .seconds(400))))
        #expect(queue.submit(try update(session: "Jarvis", at: 200), audience: audience, now: at(200))
                == .held(push: nil), "another session's budget is separate")
        #expect(queue.submit(try update(at: 600), audience: audience, now: at(600)) == .held(push: nil),
                "the first update left the window")
        #expect(queue.held.count == 4, "a refusal is not held")
    }

    @Test func aNonpositiveLimitRefusesForAWindow() throws {
        var queue = enabled { $0.perSessionLimit = 0 }
        #expect(queue.submit(try update(), audience: .init(), now: at(0))
                == .refused(.rateLimited(retryAfter: .seconds(3_600))))
    }

    @Test func drainRespectsQuietAndMedia() throws {
        let quiet = SessionUpdateAudience(quiet: true)
        let media = SessionUpdateAudience(media: true)
        var queue = enabled()
        _ = queue.submit(try update(), audience: .init(), now: at(0))
        #expect(queue.drain(.naturalPause, audience: quiet, now: at(1)).isEmpty)
        #expect(queue.drain(.naturalPause, audience: media, now: at(1)).isEmpty)
        #expect(queue.drain(.interaction, audience: quiet, now: at(1)).isEmpty)
        #expect(queue.held.count == 1, "a refused drain keeps the update")
        #expect(queue.drain(.interaction, audience: media, now: at(1)).count == 1)

        _ = queue.submit(try update(), audience: .init(), now: at(2))
        #expect(queue.drain(.asked, audience: SessionUpdateAudience(quiet: true, media: true), now: at(3)).count == 1,
                "asking always delivers")
        _ = queue.submit(try update(), audience: .init(), now: at(4))
        #expect(queue.drain(.naturalPause, audience: .init(), now: at(5)).count == 1)
        #expect(queue.held.isEmpty)
    }

    @Test func drainPutsActionFirstThenOldestFirst() throws {
        var queue = enabled()
        let first = try update(.info, spoken: "one", at: 0)
        let urgent = try update(.action, spoken: "two", at: 1)
        let last = try update(.info, spoken: "three", at: 2)
        for (each, second) in [(first, 0.0), (urgent, 1), (last, 2)] {
            _ = queue.submit(each, audience: .init(), now: at(second))
        }
        #expect(queue.drain(.asked, audience: .init(), now: at(3)).map(\.id) == [urgent.id, first.id, last.id])
    }

    @Test func fullQueueDropsTheOldestInfoAndRefusesWhenAllAreAction() throws {
        var queue = enabled { $0.capacity = 2 }
        let old = try update(.info, spoken: "old", at: 0)
        _ = queue.submit(old, audience: .init(), now: at(0))
        _ = queue.submit(try update(.action, at: 1), audience: .init(), now: at(1))
        _ = queue.submit(try update(.action, at: 2), audience: .init(), now: at(2))
        #expect(queue.held.count == 2)
        #expect(!queue.held.contains { $0.id == old.id })
        #expect(queue.submit(try update(.info, at: 3), audience: .init(), now: at(3)) == .refused(.full))
        #expect(queue.retryAfter(session: "Voice Work", now: at(3)) == nil, "a full refusal spends nothing")
    }

    @Test func heldUpdatesExpire() throws {
        var queue = enabled { $0.lifetime = .seconds(60) }
        _ = queue.submit(try update(at: 0), audience: .init(), now: at(0))
        #expect(queue.drain(.asked, audience: .init(), now: at(60)).isEmpty)
    }
}
