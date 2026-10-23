#if os(macOS)
import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit

/// Close first, then decide (#735 S-8 HS-C round 3), on the real duck control and the router's own ledger (round 4),
/// step by step: each of key 2's windows, deterministically. Synthetic only.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientPrivacyCloseFirstTests {
    static let started = Data(#"{"type": "session", "duck": {"version": 3}, "phase": "started"}"#.utf8)
    typealias Ledger = AmbientPrivacyLedger<Child>
    final class Child {}

    /// A started v3 child with an entry open on it and its on-line written.
    static func written(_ ledger: inout Ledger, wasOn: Bool = false) -> AmbientDuckControl {
        let duck = AmbientDuckControl()
        _ = duck.observe(started: started, write: { _ in true })
        _ = ledger.open(on: [(Child(), duck)], wasOn: wasOn, at: 0)
        #expect(duck.report(true, write: { _ in true }))
        return duck
    }

    /// The router's close of `entry` at `now` with every child listening: the clip and tokens, nil while it waits.
    static func announce(_ entry: Int, _ ledger: inout Ledger, now: Double = 0,
                         listening: @escaping (Child) -> Bool = { _ in true }) -> (String?, String)? {
        guard case .decided(let decision) = ledger.close(entry, now: now, bound: 16, listening: listening) else {
            return nil
        }
        return (decision.clip, decision.tokens)
    }

    /// 1. Key 2's window: the child has proved it (round 2's verdict read `kept` here), then a duplicate ack refuses it
    /// before the close. The close reads the refusal with the claim: "unavailable", said once, never "privacy on".
    @Test func aDuplicateAckBeforeTheCloseSaysUnavailable() throws {
        var ledger = Ledger()
        let duck = Self.written(&ledger)
        #expect(duck.acknowledge() == .counted)
        #expect(duck.settled == .kept)
        #expect(duck.acknowledge() == .excess)
        #expect(duck.refuseIfWished())
        #expect(!duck.takeAnnouncement())
        let (clip, tokens) = try #require(Self.announce(1, &ledger))
        #expect(clip == AmbientStopConfirmation.privacyUnavailable && tokens == " refused")
        #expect(!duck.takeAnnouncement())
    }

    /// 1b. The same duplicate just after the close is a new event: "privacy on" was true at the close, and the child's
    /// own "unavailable" follows it on the connection's chain (it is not absorbed).
    @Test func aDuplicateAckAfterTheCloseIsSaidByTheChild() throws {
        var ledger = Ledger()
        let duck = Self.written(&ledger)
        #expect(duck.acknowledge() == .counted)
        let (clip, tokens) = try #require(Self.announce(1, &ledger))
        #expect(clip == AmbientStopConfirmation.privacyOn && tokens.isEmpty)
        #expect(duck.acknowledge() == .excess && duck.refuseIfWished())
        #expect(ledger.refusal(of: duck, on: true, holders: [duck]) == (true, nil))
        #expect(ledger.said == .unavailable)
    }

    /// 3. The bound racing an ack, the ack decided first under the duck lock: kept, "privacy on", nothing refused.
    /// Decided the other way, the child's own bound refuses it ("unavailable", `timeout`), and the late ack proves
    /// nothing. Before its bound, the close waits.
    @Test func aTimeoutRacingAnAckIsDecidedByWhicheverCameFirst() throws {
        var ledger = Ledger()
        let acked = Self.written(&ledger)
        #expect(acked.acknowledge() == .counted)
        let (on, _) = try #require(Self.announce(1, &ledger, now: 16))
        #expect(on == AmbientStopConfirmation.privacyOn && acked.settled == .kept)
        let late = Self.written(&ledger)
        #expect(Self.announce(2, &ledger, now: 15.9) == nil)
        let (unavailable, tokens) = try #require(Self.announce(2, &ledger, now: 16))
        #expect(unavailable == AmbientStopConfirmation.privacyUnavailable && tokens == " timeout")
        _ = late.acknowledge()
        #expect(late.settled == .refused(.unacknowledged))
    }

    /// 4. Off then on mid-wait: the first entry is withdrawn, silent and logged, never refusing the child that now
    /// waits on the second entry's ack, even past its bound; that ack then says "privacy on" for the second entry.
    @Test func offThenOnMidWaitKeepsTheHealthyChild() throws {
        var ledger = Ledger()
        let duck = Self.written(&ledger)
        _ = duck.report(false, write: { _ in true })
        ledger.withdrawAll()
        _ = ledger.open(on: [(Child(), duck)], wasOn: false, at: 1)
        #expect(duck.report(true, write: { _ in true }))
        let withdrawn = try #require(Self.announce(1, &ledger, now: 16))
        #expect(withdrawn.0 == nil && withdrawn.1 == " withdrawn")
        #expect(duck.settled == nil)
        #expect(Self.announce(2, &ledger, now: 16) == nil)
        #expect(duck.acknowledge() == .counted && duck.acknowledge() == .counted)
        #expect(Self.announce(2, &ledger)?.0 == AmbientStopConfirmation.privacyOn)
    }

    /// 4b. A re-entry while still waiting (round 4, finding 5): the older entry closes in silence
    /// (`superseded_by_newer`), never refusing the proof the newest entry owns; the newer entry says "privacy on".
    @Test func anOlderEntryUnderANewerOneSaysNothing() throws {
        var ledger = Ledger()
        let duck = Self.written(&ledger)
        _ = ledger.open(on: [(Child(), duck)], wasOn: true, at: 1)
        let older = try #require(Self.announce(1, &ledger, now: 16))
        #expect(older.0 == nil && older.1 == " superseded_by_newer")
        #expect(duck.settled == nil)
        #expect(duck.acknowledge() == .counted)
        let newer = try #require(Self.announce(2, &ledger))
        #expect(newer.0 == AmbientStopConfirmation.privacyOn && newer.1 == " still_on")
    }

    /// 5. The state rule (round 4): a child that no longer listens (swapped out, draining or gone) refused while a
    /// listening child keeps privacy changes nothing: absorbed (`superseded_by_keep`), even once its run is gone.
    @Test func aRefusalOfAChildNoLongerListeningIsAbsorbed() throws {
        var ledger = Ledger()
        let old = AmbientDuckControl(), successor = AmbientDuckControl()
        let (oldChild, newChild) = (Child(), Child())
        for duck in [old, successor] { _ = duck.observe(started: Self.started, write: { _ in true }) }
        _ = ledger.open(on: [(oldChild, old), (newChild, successor)], wasOn: false, at: 0)
        for duck in [old, successor] { #expect(duck.report(true, write: { _ in true })) }
        #expect(old.acknowledge() == .counted && old.acknowledge() == .excess && old.refuseIfWished())
        old.end()
        #expect(successor.acknowledge() == .counted)
        let decided = try #require(Self.announce(1, &ledger) { $0 === newChild })
        #expect(decided == (AmbientStopConfirmation.privacyOn, " superseded_by_keep"))
    }

    /// 6. Nits: the start deadline after the run's end refuses nothing; re-arming a deadline key cancels the task it
    /// replaces; and a withdrawn entry with nothing claimed plays nothing, even while privacy is on again.
    @Test func theNits() async throws {
        let duck = AmbientDuckControl(startPrivate: true)
        duck.end()
        #expect(!duck.expire())
        let fired = FiredKeys()
        let deadlines = AmbientAckDeadlines()
        deadlines.arm(AmbientAckDeadlines.freshStart, after: 0.05) { _ in fired.add("first") }
        deadlines.arm(AmbientAckDeadlines.freshStart, after: 0.1) { _ in fired.add("second") }
        try await Task.sleep(for: .milliseconds(400))
        #expect(fired.all == ["second"])
        #expect(AmbientRightyoRouter.announcement(.withdrawn, claimed: false, wasOn: true) == (nil, " withdrawn"))
    }

    final class FiredKeys: Sendable {
        private let keys = Mutex<[String]>([])
        func add(_ key: String) { keys.withLock { $0.append(key) } }
        var all: [String] { keys.withLock { $0 } }
    }
}
#endif
