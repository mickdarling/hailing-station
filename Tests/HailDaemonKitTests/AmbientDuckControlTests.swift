#if os(macOS)
import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit

/// Privacy mode (internally duck) reaches only a RightyO that advertised `duck` version 3 or higher (#735 S-2, S-8). A
/// v1 RightyO still transcribes while ducked, a v2 one never acks, and an older one skips the line, so none is ever
/// written one, and the host is told it did not take it (fail closed). Synthetic only.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientDuckControlTests {
    static let started = #"{"type": "session", "phase": "started", "capabilities": {}}"#
    static let advertised = #"{"type": "session", "phase": "started", "duck": {"version": 3}}"#

    /// Every line a control was asked to write.
    final class Written: Sendable {
        private let lines = Mutex<[Bool]>([])
        var all: [Bool] { lines.withLock { $0 } }
        func write(_ on: Bool) -> Bool {
            lines.withLock { $0.append(on) }
            return true
        }
    }

    @Test func aChildThatAdvertisedDuckIsWrittenEveryChange() {
        let (control, written) = (AmbientDuckControl(), Written())
        #expect(control.observe(started: Data(Self.advertised.utf8), write: written.write) == .kept)
        #expect(control.report(true, write: written.write) && control.active)
        #expect(control.report(false, write: written.write) && !control.active)
        #expect(written.all == [true, false])
    }

    @Test func anOlderChildIsNeverWrittenAndNeverTookIt() {
        let (control, written) = (AmbientDuckControl(), Written())
        #expect(control.observe(started: Data(Self.started.utf8), write: written.write) == .kept)
        #expect(!control.report(true, write: written.write) && !control.report(false, write: written.write))
        #expect(written.all.isEmpty)
    }

    /// A wish made before `started` (a reloaded child while duck mode is on) is written once a capable child starts,
    /// and a later `started` never changes what the first one said.
    @Test func aWishBeforeStartedIsWrittenOnceTheChildAdvertisesIt() {
        let (control, written) = (AmbientDuckControl(), Written())
        // A child not yet started takes the wish: it is written at `started`, or the child is refused then.
        #expect(control.report(true, write: written.write))
        #expect(control.observe(started: Data(Self.advertised.utf8), write: written.write) == .kept)
        #expect(control.observe(started: Data(Self.started.utf8), write: written.write) == .kept)
        #expect(control.report(false, write: written.write))
        #expect(written.all == [true, false])
    }

    /// A child that starts without `duck` v3 while privacy is wished for (the spawn-to-started race) is refused (the
    /// pipeline kills it), never written, and still counts as private: privacy is never lost (#735 round 2).
    @Test func aWishAnOlderChildCannotTakeIsRefusedAndKeptPrivate() {
        let (control, written) = (AmbientDuckControl(), Written())
        #expect(control.report(true, write: written.write) && control.active)
        #expect(control.observe(started: Data(Self.started.utf8), write: written.write) == .refused)
        #expect(control.active && written.all.isEmpty)
        let (idle, none) = (AmbientDuckControl(), Written())
        #expect(idle.observe(started: Data(Self.started.utf8), write: none.write) == .kept)
    }

    /// HS-C: a `kept()` waiter whose task is cancelled answers false and is resumed once: the proof that comes later
    /// finds no waiter left. A task cancelled before it waits answers false too.
    @Test func aCancelledWaiterAnswersFalse() async {
        let (control, written) = (AmbientDuckControl(), Written())
        #expect(control.observe(started: Data(Self.advertised.utf8), write: written.write) == .kept)
        #expect(control.report(true, write: written.write))
        let waiter = Task { await control.kept() }
        try? await Task.sleep(for: .milliseconds(50))
        waiter.cancel()
        #expect(await waiter.value == false)
        let early = Task {
            while !Task.isCancelled { await Task.yield() }
            return await control.kept()
        }
        early.cancel()
        #expect(await early.value == false)
        #expect(control.acknowledge() == .counted)
        #expect(await control.kept())
    }

    /// HS-B's nits: once the run ended, a deadline already past its cancel check refuses nothing (so `run()` ends the
    /// control before closing its deadlines), and a child refused at its deadline is written no further on-line.
    @Test func anEndedRunRefusesNothingAndAnUnackedChildIsNotWrittenAgain() {
        let (control, written) = (AmbientDuckControl(), Written())
        #expect(control.observe(started: Data(Self.advertised.utf8), write: written.write) == .kept)
        #expect(control.report(true, write: written.write) && control.expireAck(1))
        #expect(control.report(false, write: written.write))
        #expect(!control.report(true, write: written.write))
        #expect(written.all == [true, false])
        let (ended, lines) = (AmbientDuckControl(), Written())
        #expect(ended.observe(started: Data(Self.advertised.utf8), write: lines.write) == .kept)
        #expect(ended.report(true, write: lines.write))
        ended.end()
        #expect(!ended.expireAck(1) && ended.refusal == nil)
    }

    @Test(arguments: [
        #"{"duck": true}"#, #"{"duck": null}"#, #"{"duck": [1]}"#, "[]", "not json", #"{}"#, #"{"duck": {}}"#,
        #"{"duck": {"version": 1}}"#, #"{"duck": {"version": "2"}}"#, #"{"duck": {"version": 1.5}}"#,
        #"{"duck": {"version": true}}"#, #"{"duck": {"version": 2}}"#, #"{"duck": {"version": 2, "private": true}}"#
    ])
    func onlyVersionThreeOrLaterAdvertisesPrivacy(_ line: String) {
        #expect(!AmbientDuckControl.advertises(Data(line.utf8)))
    }

    @Test(arguments: [3, 4]) func versionThreeOrLaterAdvertisesPrivacy(_ version: Int) {
        #expect(AmbientDuckControl.advertises(Data(#"{"duck": {"version": \#(version)}}"#.utf8)))
    }

    /// End to end in one pipeline: the entry asks the child to go private; only a v3 child is written the line and
    /// reports that it took it, never a v2 one (it would not ack). The entry's handling is awaited as a signal, not polled for, and the
    /// teardown graces are short, so a loaded parallel run cannot push it past its time limit.
    @Test(arguments: [true, false]) func onlyAVersionThreeChildTakesPrivacy(_ advertises: Bool) async throws {
        let fake = try FakeRightyo(FakeRightyo.ackingControl() + "\n"
            + AmbientPrivacyEntryTests.fixture(saying: "Rightyo, stop recording.", advertises: true,
                                               version: advertises ? 3 : 2))
        defer { fake.cleanUp() }
        try fake.install(fixture: "enrolled-formed-request.jsonl")
        let box = Mutex<RightyoAmbientPipeline?>(nil), took = Mutex<[Bool]>([])
        var configuration = RightyoAmbientPipeline.Configuration(
            executable: fake.executable, config: fake.config, target: "tmux:demo", binding: "pinned",
            connection: UUID(), allowSynthetic: true, timing: .init(eofGrace: 5, termGrace: 5)
        )
        let (handled, signal) = AsyncStream<Bool>.makeStream()
        configuration.replyControl = true
        configuration.onVoiceDuck = { command in
            guard command == .enter, let pipeline = box.withLock({ $0 }) else { return }
            let taken = pipeline.reportDuck(true)
            took.withLock { $0.append(taken) }
            signal.yield(taken)
        }
        let dispatcher = RecordingAmbientDispatcher()
        let pipeline = try RightyoAmbientPipeline(configuration: configuration, dispatcher: dispatcher)
        box.withLock { $0 = pipeline }
        // Input stays open until the entry was handled: closing it closes the control descriptor too.
        // A run that ends without the entry finishes the signal, so the wait fails instead of hanging.
        let run = Task {
            defer { signal.finish() }
            return try await pipeline.run().delivered
        }
        var entries = handled.makeAsyncIterator()
        #expect(await entries.next() == advertises)
        pipeline.finishInput()
        #expect(try await run.value == 0)
        #expect(took.withLock { $0 } == [advertises])
        let expected = advertises ? "{\"duck\":true}\n" : ""
        #expect(await eventually { (try? fake.recorded("control.txt")) == expected })
        box.withLock { $0 = nil }
    }
}
#endif
