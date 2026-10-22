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

    /// Every line a control would write, and the control writing them.
    final class Written: Sendable {
        private let lines = Mutex<[Bool]>([])
        var all: [Bool] { lines.withLock { $0 } }
        func control() -> AmbientDuckControl {
            AmbientDuckControl { [self] on in
                lines.withLock { $0.append(on) }
                return true
            }
        }
    }

    private func control() -> (AmbientDuckControl, Written) {
        let written = Written()
        return (written.control(), written)
    }

    @Test func aChildThatAdvertisedDuckIsWrittenEveryChange() {
        let (control, written) = control()
        control.observe(started: Data(Self.advertised.utf8))
        #expect(control.report(true) && control.report(false))
        #expect(written.all == [true, false])
    }

    @Test func anOlderChildIsNeverWrittenAndNeverTookIt() {
        let (control, written) = control()
        control.observe(started: Data(Self.started.utf8))
        #expect(!control.report(true) && !control.report(false))
        #expect(written.all.isEmpty)
    }

    /// A wish made before `started` (a reloaded child while duck mode is on) is written once a capable child starts,
    /// and a later `started` never changes what the first one said.
    @Test func aWishBeforeStartedIsWrittenOnceTheChildAdvertisesIt() {
        let (control, written) = control()
        #expect(!control.report(true))
        control.observe(started: Data(Self.advertised.utf8))
        control.observe(started: Data(Self.started.utf8))
        #expect(control.report(false))
        #expect(written.all == [true, false])
        let (older, none) = self.control()
        #expect(!older.report(true))
        older.observe(started: Data(Self.started.utf8))
        #expect(none.all.isEmpty)
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
