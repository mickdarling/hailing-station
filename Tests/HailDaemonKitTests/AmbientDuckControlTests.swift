#if os(macOS)
import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit

/// Duck mode reaches only a RightyO that advertised it (#735 H-2). An older RightyO skips an unknown control line and
/// goes on deciding turns, so it is never written one, and the host is told it did not take it. Synthetic only.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientDuckControlTests {
    static let started = #"{"type": "session", "phase": "started", "capabilities": {}}"#
    static let advertised = #"{"type": "session", "phase": "started", "duck": {"version": 1}}"#

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

    @Test(arguments: [#"{"duck": true}"#, #"{"duck": null}"#, #"{"duck": [1]}"#, "[]", "not json", #"{}"#])
    func onlyAnObjectAdvertisesDuck(_ line: String) {
        #expect(!AmbientDuckControl.advertises(Data(line.utf8)))
        #expect(AmbientDuckControl.advertises(Data(#"{"duck": {}}"#.utf8)))
    }

    /// End to end in one pipeline: the owner's entry asks the child to duck; only an advertising child is written the
    /// line and reports that it took it.
    @Test(arguments: [true, false]) func onlyAnAdvertisingChildTakesDuckMode(_ advertises: Bool) async throws {
        let fake = try FakeRightyo("/bin/cat <&3 > control.txt &\n"
            + AmbientVoiceDuckTests.fixture(saying: "Rightyo, duck mode.", advertises: advertises))
        defer { fake.cleanUp() }
        try fake.install(fixture: "enrolled-formed-request.jsonl")
        let box = Mutex<RightyoAmbientPipeline?>(nil), took = Mutex<[Bool]>([])
        var configuration = RightyoAmbientPipeline.Configuration(
            executable: fake.executable, config: fake.config, target: "tmux:demo", binding: "pinned",
            connection: UUID(), allowSynthetic: true, timing: .init(eofGrace: 20, termGrace: 20)
        )
        configuration.replyControl = true
        configuration.onVoiceDuck = { command in
            guard command == .on, let pipeline = box.withLock({ $0 }) else { return }
            took.withLock { $0.append(pipeline.reportDuck(true)) }
        }
        let dispatcher = RecordingAmbientDispatcher()
        let pipeline = try RightyoAmbientPipeline(configuration: configuration, dispatcher: dispatcher)
        box.withLock { $0 = pipeline }
        // Input stays open until the entry was handled: closing it closes the control descriptor too.
        let run = Task { try await pipeline.run().delivered }
        #expect(await eventually { took.withLock { !$0.isEmpty } })
        pipeline.finishInput()
        #expect(try await run.value == 0)
        #expect(took.withLock { $0 } == [advertises])
        let expected = advertises ? "{\"duck\":true}\n" : ""
        #expect(await eventually { (try? fake.recorded("control.txt")) == expected })
        box.withLock { $0 = nil }
    }
}
#endif
