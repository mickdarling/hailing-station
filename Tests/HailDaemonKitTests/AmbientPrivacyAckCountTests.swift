#if os(macOS)
import Foundation
import Testing
@testable import HailDaemonKit

/// The privacy-on ack gate's counting (#735 S-8 HS-B), beside `AmbientPrivacyAckGateTests` so each file stays within
/// the length limit: acks match on-writes by count, are never banked, and `at_ms` is never computed with.
extension AmbientPrivacyAckGateTests {
    /// 2. On, off, on: the first write's ack (late) counts for that write only, so it cannot open the gate for the
    /// second on; the second ack does.
    @Test func aStaleAckCannotOpenTheGateForALaterOn() {
        let (control, written) = (AmbientDuckControl(), AmbientDuckControlTests.Written())
        var writes: [Int] = []
        let note: (Int) -> Void = { write in writes.append(write) }
        #expect(control.observe(started: Self.started, write: written.write, written: note) == .kept)
        #expect(control.report(true, write: written.write, written: note) && !control.mayHearAudio)
        #expect(control.report(false, write: written.write, written: note) && control.mayHearAudio)
        #expect(control.report(true, write: written.write, written: note) && !control.mayHearAudio)
        #expect(control.acknowledge() == .counted && !control.mayHearAudio)
        #expect(control.acknowledge() == .counted && control.mayHearAudio)
        #expect(written.all == [true, false, true] && writes == [1, 2])
    }

    /// An ack that comes after the off it raced consumes its own write only and never sets `keeps`: the next on is
    /// written again (not skipped as already kept) and needs its own ack.
    @Test func aLateAckAfterOffKeepsNothing() {
        let (control, written) = (AmbientDuckControl(), AmbientDuckControlTests.Written())
        #expect(control.observe(started: Self.started, write: written.write) == .kept)
        #expect(control.report(true, write: written.write) && !control.mayHearAudio)
        #expect(control.report(false, write: written.write) && control.mayHearAudio)
        #expect(control.acknowledge() == .counted && control.mayHearAudio)
        #expect(control.report(true, write: written.write) && !control.mayHearAudio)
        #expect(written.all == [true, false, true])
        #expect(control.acknowledge() == .counted && control.mayHearAudio)
    }

    /// 3. An ack with no on-write outstanding is excess, never counted: one sent ahead does not open the gate for the
    /// next write, nor does one more after the proof.
    @Test func anExcessAckIsNeverBanked() {
        let (control, written) = (AmbientDuckControl(), AmbientDuckControlTests.Written())
        #expect(control.observe(started: Self.started, write: written.write) == .kept)
        #expect(control.acknowledge() == .excess)
        #expect(control.report(true, write: written.write) && !control.mayHearAudio)
        #expect(control.acknowledge() == .counted && control.mayHearAudio)
        #expect(control.acknowledge() == .excess && control.mayHearAudio)
        _ = control.report(false, write: written.write)
        #expect(control.acknowledge() == .excess)
    }

    /// 8. `privacyKept()` answers false when the wish is withdrawn, and when the run ends without an ack.
    @Test func privacyKeptIsFalseWhenWithdrawnOrAtTheRunsEnd() async throws {
        let fake = try Gate.fake(Self.script(acks: false))
        defer { fake.cleanUp() }
        let pipeline = try Self.pipeline(fake)
        #expect(await pipeline.privacyKept() == false)
        #expect(pipeline.reportDuck(true))
        let withdrawn = Task { await pipeline.privacyKept() }
        let run = Task { try await pipeline.run() }
        #expect(await eventually { Self.control(fake) == "{\"duck\":true}\n" })
        _ = pipeline.reportDuck(false)
        #expect(await withdrawn.value == false)
        #expect(pipeline.reportDuck(true))
        let ended = Task { await pipeline.privacyKept() }
        pipeline.finishInput()
        _ = try await run.value
        #expect(await ended.value == false)
    }

    /// 9. `at_ms` is the child's unbounded clock: an ack at `Int.max` is counted like any other and traps nothing.
    @Test func anAckNearIntMaxDoesNotTrap() async throws {
        let fake = try Gate.fake(Self.script(atMs: String(Int.max), prelude: "/usr/bin/touch go"))
        defer { fake.cleanUp() }
        let pipeline = try Self.pipeline(fake)
        #expect(pipeline.reportDuck(true))
        let run = Task { try await pipeline.run() }
        #expect(await pipeline.privacyKept())
        #expect(pipeline.hearsAudio)
        pipeline.finishInput()
        _ = try await run.value
    }
}
#endif
