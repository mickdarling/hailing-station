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
        let first = queue.hold(action, at: at(1))
        let again = queue.hold(action, at: at(1))
        #expect(first && again, "holding the same update twice keeps one copy")
        #expect(queue.held.map(\.id) == [action.id])
        #expect(queue.retryAfter(session: "Voice Work", now: at(1)) == .seconds(3_599))
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

@Suite struct SessionUpdateShapeTests {
    let now = ContinuousClock().now

    @Test func fieldsAreTrimmedAndBounded() {
        let made = SessionUpdate(session: " Jarvis ", priority: .info, spoken: " Done. ", card: "  ", submitted: now)
        #expect(made?.session == "Jarvis")
        #expect(made?.spoken == "Done.")
        #expect(made?.card == nil, "a blank card is no card")
        #expect(SessionUpdate(session: "", priority: .info, spoken: "Done", submitted: now) == nil)
        #expect(SessionUpdate(session: "Jarvis", priority: .info, spoken: "  ", submitted: now) == nil)
        let long = String(repeating: "a", count: SessionUpdate.maxSpokenBytes + 1)
        #expect(SessionUpdate(session: "Jarvis", priority: .info, spoken: long, submitted: now) == nil)
        let card = String(repeating: "c", count: SessionUpdate.maxCardBytes + 1)
        #expect(SessionUpdate(session: "Jarvis", priority: .info, spoken: "ok", card: card, submitted: now) == nil)
    }

    @Test func digestNamesEachSpeaker() throws {
        #expect(SessionUpdateQueue.digest([]) == nil)
        let one = try #require(SessionUpdate(session: "Jarvis", priority: .info, spoken: "PR is green", submitted: now))
        #expect(SessionUpdateQueue.digest([one]) == "Jarvis: PR is green.")
        let two = try #require(SessionUpdate(session: "Voice Work", priority: .action, spoken: "Need a decision?",
                                             submitted: now))
        #expect(SessionUpdateQueue.digest([two, one])
                == "You have 2 updates. Voice Work: Need a decision? Jarvis: PR is green.")
    }

    @Test func quietHoursWrapMidnight() throws {
        let night = try #require(SessionUpdateQuietHours(start: 22 * 60, end: 7 * 60))
        #expect(night.contains(minuteOfDay: 23 * 60))
        #expect(night.contains(minuteOfDay: 6 * 60 + 59))
        #expect(!night.contains(minuteOfDay: 7 * 60))
        #expect(!night.contains(minuteOfDay: 12 * 60))
        let lunch = try #require(SessionUpdateQuietHours(start: 12 * 60, end: 13 * 60))
        #expect(lunch.contains(minuteOfDay: 12 * 60 + 30))
        #expect(!lunch.contains(minuteOfDay: 13 * 60))
        #expect(SessionUpdateQuietHours(start: 0, end: 0)?.contains(minuteOfDay: 0) == false)
        #expect(SessionUpdateQuietHours(start: -1, end: 10) == nil)
        #expect(SessionUpdateQuietHours(start: 0, end: 24 * 60) == nil)
    }
}
