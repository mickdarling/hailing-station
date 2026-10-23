#if os(macOS)
import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit

/// Close first, then decide (#735 S-8 HS-C round 3), on the real duck control and the router's own close, verdict and
/// announcement, step by step: each of key 2's windows, deterministically. Synthetic only.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientPrivacyCloseFirstTests {
    static let started = Data(#"{"type": "session", "duck": {"version": 3}, "phase": "started"}"#.utf8)

    /// A started v3 child with entry `entry` open and its on-line written.
    static func written(entry: Int = 1) -> AmbientDuckControl {
        let duck = AmbientDuckControl()
        _ = duck.observe(started: started, write: { _ in true })
        duck.open(entry: entry)
        #expect(duck.report(true, write: { _ in true }))
        return duck
    }

    /// The router's close and verdict for one listening child: the clip and tokens.
    static func announce(_ entry: Int, _ duck: AmbientDuckControl, withdrawn: Bool = false, timedOut: Bool = false,
                         wasOn: Bool = false) -> (String?, String)? {
        guard let closed = AmbientRightyoRouter.closeEntry(entry, children: [.init(duck: duck, listening: true)],
                                                           withdrawn: withdrawn, timedOut: timedOut) else { return nil }
        let answers = closed.map(\.0)
        let answer = AmbientRightyoRouter.privacyVerdict(answers, withdrawn: withdrawn)
        return AmbientRightyoRouter.announcement(answer, claimed: answers.contains(where: \.claimed), wasOn: wasOn)
    }

    /// 1. Key 2's window: the child has proved it (round 2's verdict read `kept` here), then a duplicate ack refuses it
    /// before the close. The close reads the refusal with the claim: "unavailable", said once, never "privacy on".
    @Test func aDuplicateAckBeforeTheCloseSaysUnavailable() throws {
        let duck = Self.written()
        #expect(duck.acknowledge() == .counted)
        #expect(duck.settled == .kept)
        #expect(duck.acknowledge() == .excess)
        #expect(duck.refuseIfWished())
        #expect(!duck.takeAnnouncement())
        let (clip, tokens) = try #require(Self.announce(1, duck))
        #expect(clip == AmbientStopConfirmation.privacyUnavailable && tokens == " refused")
        #expect(!duck.takeAnnouncement())
    }

    /// 1b. The same duplicate just after the close is a new event: "privacy on" was true at the close, and the child's
    /// own "unavailable" follows it on the connection's chain (it is not absorbed).
    @Test func aDuplicateAckAfterTheCloseIsSaidByTheChild() throws {
        let duck = Self.written()
        #expect(duck.acknowledge() == .counted)
        let (clip, tokens) = try #require(Self.announce(1, duck))
        #expect(clip == AmbientStopConfirmation.privacyOn && tokens.isEmpty)
        #expect(duck.acknowledge() == .excess && duck.refuseIfWished())
        #expect(duck.takeAnnouncement())
    }

    /// 3. The bound racing an ack, the ack decided first under the duck lock: kept, "privacy on", nothing refused.
    /// Decided the other way, the bound refuses it ("unavailable", `timeout`), and the late ack proves nothing.
    @Test func aTimeoutRacingAnAckIsDecidedByWhicheverCameFirst() throws {
        let acked = Self.written()
        #expect(acked.acknowledge() == .counted)
        let (on, _) = try #require(Self.announce(1, acked, timedOut: true))
        #expect(on == AmbientStopConfirmation.privacyOn && acked.settled == .kept)
        let late = Self.written()
        let (unavailable, tokens) = try #require(Self.announce(1, late, timedOut: true))
        #expect(unavailable == AmbientStopConfirmation.privacyUnavailable && tokens == " timeout")
        _ = late.acknowledge()
        #expect(late.settled == .refused(.unacknowledged))
    }

    /// 4. Off then on mid-wait: the first entry is withdrawn, silent and logged, never refusing the child that now
    /// waits on the second entry's ack, even at its bound; that ack then says "privacy on" for the second entry.
    @Test func offThenOnMidWaitKeepsTheHealthyChild() throws {
        let duck = Self.written()
        _ = duck.report(false, write: { _ in true })
        duck.open(entry: 2)
        #expect(duck.report(true, write: { _ in true }))
        let withdrawn = try #require(Self.announce(1, duck, withdrawn: true, timedOut: true))
        #expect(withdrawn.0 == nil && withdrawn.1 == " withdrawn")
        #expect(duck.settled == nil)
        #expect(Self.announce(2, duck) == nil)
        #expect(duck.acknowledge() == .counted && duck.acknowledge() == .counted)
        #expect(Self.announce(2, duck)?.0 == AmbientStopConfirmation.privacyOn)
    }

    /// 4b. A re-entry while still waiting: the newest open entry owns the pending proof, so the older one's bound
    /// leaves the child alone (it says `timeout`); the newer entry decides it.
    @Test func anOlderEntrysBoundLeavesTheNewestEntrysProof() throws {
        let duck = Self.written()
        duck.open(entry: 2)
        let older = try #require(Self.announce(1, duck, timedOut: true))
        #expect(older.0 == AmbientStopConfirmation.privacyUnavailable && older.1 == " timeout")
        #expect(duck.settled == nil)
        #expect(duck.acknowledge() == .counted)
        let newer = try #require(Self.announce(2, duck, wasOn: true))
        #expect(newer.0 == AmbientStopConfirmation.privacyOn && newer.1 == " still_on")
    }

    /// 5. A replaced child is known as replaced by the child itself, so its refusal never decides the verdict (its
    /// successor answers), even once its run is gone.
    @Test func aReplacedChildStaysReplaced() throws {
        let old = Self.written()
        old.markReplaced()
        #expect(old.acknowledge() == .counted && old.acknowledge() == .excess && old.refuseIfWished())
        old.end()
        let successor = Self.written()
        #expect(successor.acknowledge() == .counted)
        let children: [AmbientPrivacyEntryChild] = [.init(duck: old, listening: false),
                                                    .init(duck: successor, listening: true)]
        let closed = try #require(AmbientRightyoRouter.closeEntry(1, children: children, withdrawn: false,
                                                                 timedOut: false))
        #expect(closed[0].0.retired && closed[0].0.claimed)
        let answer = AmbientRightyoRouter.privacyVerdict(closed.map(\.0), withdrawn: false)
        #expect(AmbientRightyoRouter.announcement(answer, claimed: true, wasOn: false)
            == (AmbientStopConfirmation.privacyOn, " superseded_by_keep"))
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
