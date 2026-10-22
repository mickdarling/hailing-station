#if os(macOS)
import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit

/// Privacy mode (internally duck) reaches only a RightyO that advertised `duck` version 2 or higher (#735 S-2). A v1
/// RightyO still transcribes while ducked, and an older one skips the line, so neither is ever written one, and the
/// host is told it did not take it (fail closed). Synthetic only.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientDuckControlTests {
    static let started = #"{"type": "session", "phase": "started", "capabilities": {}}"#
    static let advertised = #"{"type": "session", "phase": "started", "duck": {"version": 2}}"#

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
        #expect(!control.observe(started: Data(Self.advertised.utf8), write: written.write))
        #expect(control.report(true, write: written.write) && control.active)
        #expect(control.report(false, write: written.write) && !control.active)
        #expect(written.all == [true, false])
    }

    @Test func anOlderChildIsNeverWrittenAndNeverTookIt() {
        let (control, written) = (AmbientDuckControl(), Written())
        #expect(!control.observe(started: Data(Self.started.utf8), write: written.write))
        #expect(!control.report(true, write: written.write) && !control.report(false, write: written.write))
        #expect(written.all.isEmpty)
    }

    /// A wish made before `started` (a reloaded child while duck mode is on) is written once a capable child starts,
    /// and a later `started` never changes what the first one said.
    @Test func aWishBeforeStartedIsWrittenOnceTheChildAdvertisesIt() {
        let (control, written) = (AmbientDuckControl(), Written())
        #expect(!control.report(true, write: written.write))
        #expect(!control.observe(started: Data(Self.advertised.utf8), write: written.write))
        #expect(!control.observe(started: Data(Self.started.utf8), write: written.write))
        #expect(control.report(false, write: written.write))
        #expect(written.all == [true, false])
    }

    /// A child that starts without `duck` while duck mode is wished for is reported, never written, and no longer
    /// counts as ducking, so its exit phrase is a request again.
    @Test func aWishAnOlderChildCannotTakeIsDroppedAndReported() {
        let (control, written) = (AmbientDuckControl(), Written())
        #expect(!control.report(true, write: written.write) && control.active)
        #expect(control.observe(started: Data(Self.started.utf8), write: written.write))
        #expect(!control.active && written.all.isEmpty)
        let (idle, none) = (AmbientDuckControl(), Written())
        #expect(!idle.observe(started: Data(Self.started.utf8), write: none.write))
    }

    @Test(arguments: [
        #"{"duck": true}"#, #"{"duck": null}"#, #"{"duck": [1]}"#, "[]", "not json", #"{}"#, #"{"duck": {}}"#,
        #"{"duck": {"version": 1}}"#, #"{"duck": {"version": "2"}}"#, #"{"duck": {"version": 1.5}}"#,
        #"{"duck": {"version": true}}"#
    ])
    func onlyVersionTwoOrLaterAdvertisesPrivacy(_ line: String) {
        #expect(!AmbientDuckControl.advertises(Data(line.utf8)))
    }

    @Test(arguments: [2, 3]) func versionTwoOrLaterAdvertisesPrivacy(_ version: Int) {
        #expect(AmbientDuckControl.advertises(Data(#"{"duck": {"version": \#(version)}}"#.utf8)))
    }

    /// End to end in one pipeline: the entry asks the child to go private; only a v2 child is written the line and
    /// reports that it took it, never a v1 one. The entry's handling is awaited as a signal, not polled for, and the
    /// teardown graces are short, so a loaded parallel run cannot push it past its time limit.
    @Test(arguments: [true, false]) func onlyAVersionTwoChildTakesPrivacy(_ advertises: Bool) async throws {
        let fake = try FakeRightyo("/bin/cat <&3 > control.txt &\n"
            + AmbientPrivacyEntryTests.fixture(saying: "Rightyo, stop recording.", advertises: true,
                                               version: advertises ? 2 : 1))
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
