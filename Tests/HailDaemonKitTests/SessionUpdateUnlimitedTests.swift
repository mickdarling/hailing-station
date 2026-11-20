import Foundation
import Testing
@testable import HailDaemonKit

/// #1258: queue-only synthetic submissions, no renderer, device or live configuration.
@Suite struct SessionUpdateUnlimitedTests {
    let fixture = SessionUpdateQueueTests()

    @Test(arguments: SessionUpdatePriority.allCases, [false, true])
    func fiftyDefaultSubmissionsAreAccepted(priority: SessionUpdatePriority, listening: Bool) throws {
        var queue = fixture.enabled()
        #expect(queue.policy.perSessionLimit == nil)
        let audience = SessionUpdateAudience(listeningDevice: listening ? fixture.phone : nil)
        for second in 0..<50 {
            let update = try fixture.update(priority, at: Double(second))
            let decision = queue.submit(update, audience: audience, now: update.submitted)
            if priority == .action && listening {
                #expect(decision == .speak(update, device: fixture.phone))
            } else {
                #expect(decision == .held(push: nil))
                #expect(queue.drain(.asked, audience: audience, now: update.submitted) == [update])
            }
            #expect(queue.retryAfter(session: update.session, now: update.submitted) == nil)
            #expect(queue.sent.isEmpty, "unlimited sends retain no timestamps or session keys")
        }
    }

    @Test(arguments: SessionUpdatePriority.allCases)
    func fiftyCardsReachTheSyntheticTransport(priority: SessionUpdatePriority) async throws {
        let rig = try await SilentUpdateRig.make()
        for _ in 0..<50 { #expect(await rig.submit(priority).outcome == .delivered) }
        #expect(rig.sends == 50)
        #expect(await rig.listener.sessionUpdates.held.isEmpty)
        #expect(await rig.listener.sessionUpdates.sent.isEmpty)
        await rig.listener.stop()
    }

    @Test func removingACapClearsItsHistory() throws {
        var queue = fixture.enabled { $0.perSessionLimit = 1 }
        let update = try fixture.update(.action)
        _ = queue.submit(update, audience: .init(listeningDevice: fixture.phone), now: fixture.at(0))
        #expect(!queue.sent.isEmpty)
        queue.policy.perSessionLimit = nil
        #expect(queue.sent.isEmpty)
        #expect(queue.retryAfter(session: update.session, now: fixture.at(0)) == nil)
    }

    @Test func configuredCapRefusalsDoNotSpendAndWindowReopens() throws {
        var queue = fixture.enabled { ($0.perSessionLimit, $0.window) = (2, .seconds(60)) }
        let audience = SessionUpdateAudience(listeningDevice: fixture.phone)
        for second in [0.0, 10] {
            let update = try fixture.update(.action, at: second)
            #expect(queue.submit(update, audience: audience, now: fixture.at(second))
                    == .speak(update, device: fixture.phone))
        }
        let before = queue
        for second in [20.0, 30] {
            #expect(queue.submit(try fixture.update(.action, at: second), audience: audience, now: fixture.at(second))
                    == .refused(.rateLimited(retryAfter: .seconds(60 - second))))
            #expect(queue == before, "a refusal must not spend or hold anything")
        }
        let next = try fixture.update(.action, at: 60)
        #expect(queue.submit(next, audience: audience, now: fixture.at(60)) == .speak(next, device: fixture.phone))
        #expect(queue.sent[next.session]?.count == 2, "expired timestamp pruned on accepted send")
    }

    @Test func defaultHeldBoundsAndLifetimeStayUnchanged() throws {
        var queue = fixture.enabled()
        #expect(queue.policy.capacity == 20 && queue.policy.perSessionHeld == 5)
        #expect(queue.policy.lifetime == .seconds(4 * 3_600))
        for index in 0..<20 {
            let update = try fixture.update(.action, session: "session-\(index / 5)")
            #expect(queue.submit(update, audience: .init(), now: fixture.at(0)) == .held(push: nil))
            if index == 4 {
                #expect(queue.submit(try fixture.update(.action, session: "session-0"),
                                     audience: .init(), now: fixture.at(0)) == .refused(.full))
            }
        }
        #expect(queue.submit(try fixture.update(.action, session: "session-4"),
                             audience: .init(), now: fixture.at(0)) == .refused(.full))
        #expect(queue.held.count == 20 && queue.sent.isEmpty)
        let stale = try fixture.update(.action)
        #expect(queue.hold(stale, audience: .init(), at: fixture.at(14_399)) == .refused(.full))
        #expect(queue.hold(stale, audience: .init(), at: fixture.at(14_400)) == .refused(.expired))
        #expect(queue.held.isEmpty)
    }
}
