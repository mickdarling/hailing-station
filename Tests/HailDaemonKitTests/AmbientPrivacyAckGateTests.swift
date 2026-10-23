#if os(macOS)
import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit

/// The privacy-on ack gate (#735 S-8 HS-B): a child keeps privacy only once it has acked every `{"duck":true}` written
/// to it, so no private audio reaches it before that proof. Acks are matched to on-writes by count, an excess one is a
/// protocol error, and one that never comes refuses the child at the deadline. Synthetic only.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientPrivacyAckGateTests {
    typealias Gate = AmbientPrivacyAudioGateTests
    static let started = Data(#"{"type": "session", "phase": "started", "duck": {"version": 3}}"#.utf8)

    /// `started` (v3), every stdin byte to `audio.raw`, and each `{"duck":true}` acked only once the test creates `go`
    /// (`acks` false: never; control lines are only recorded), with `at_ms` set to `atMs`; then `stopped`. `prelude` runs first.
    static func script(version: Int = 3, acks: Bool = true, atMs: String = "0", prelude: String = "") -> String {
        """
        \(prelude)
        ACK_AT_MS=\(atMs)
        \(acks ? FakeRightyo.ackingControl() : "/bin/cat <&3 > control.txt &")
        /usr/bin/sed -n -e '1p' events.jsonl | /usr/bin/sed -e "s/formed-demo/$7/g" \
          -e 's/"phase": "started"/"duck": {"version": \(version)}, "phase": "started"/'
        exec 4<&0
        /bin/cat <&4 > audio.raw &
        \(acks ? "while [ ! -e go ]; do /bin/sleep 0.02; done\n\(FakeRightyo.acksMayFollow)" : "")
        wait
        /usr/bin/sed -n -e '$p' events.jsonl | /usr/bin/sed -e "s/formed-demo/$7/g"\(FakeRightyo.lastSequence)
        """
    }

    /// A pipeline over `fake` that records what reached `onVoiceDuck`, with the ack deadline `deadline`.
    /// What reached `onVoiceDuck`, in order.
    final class Seen: Sendable {
        private let list = Mutex<[PrivacyCommand]>([])
        var all: [PrivacyCommand] { list.withLock { $0 } }
        func append(_ command: PrivacyCommand) { list.withLock { $0.append(command) } }
    }

    static func pipeline(_ fake: FakeRightyo, deadline: TimeInterval = 10,
                         seen: Seen? = nil) throws -> RightyoAmbientPipeline {
        var configuration = RightyoAmbientPipeline.Configuration(
            executable: fake.executable, config: fake.config, target: "tmux:demo", binding: "pinned",
            connection: UUID(), allowSynthetic: true, timing: .init(eofGrace: 20, termGrace: 20)
        )
        configuration.replyControl = true
        configuration.onVoiceDuck = { command in seen?.append(command) }
        configuration.ackDeadline = deadline
        return try RightyoAmbientPipeline(configuration: configuration, dispatcher: RecordingAmbientDispatcher())
    }

    static func control(_ fake: FakeRightyo) -> String { (try? fake.recorded("control.txt")) ?? "" }
    static func go(_ fake: FakeRightyo) {
        FileManager.default.createFile(atPath: fake.directory.appendingPathComponent("go").path, contents: nil)
    }

    /// 1. Nothing the host sends between the duck write and the ack reaches the child; what follows the ack does.
    @Test func noAudioReachesTheChildBetweenTheWriteAndTheAck() async throws {
        let fake = try Gate.fake(Self.script())
        defer { fake.cleanUp() }
        let pipeline = try Self.pipeline(fake)
        #expect(pipeline.reportDuck(true))
        let run = Task { try await pipeline.run() }
        #expect(await eventually { Self.control(fake) == "{\"duck\":true}\n" })
        #expect(!pipeline.hearsAudio)
        for _ in 0..<3 { #expect(pipeline.send(audio: Gate.chunk(0x11))) }
        Self.go(fake)
        #expect(await eventually { pipeline.hearsAudio })
        #expect(pipeline.send(audio: Gate.chunk(0x22)))
        pipeline.finishInput()
        _ = try await run.value
        #expect(await eventually { Gate.heard(fake).contains(0x22) })
        #expect(!Gate.heard(fake).contains(0x11))
    }

    /// 3, through the pipeline: an unsolicited ack ends the stream as invalid input. While privacy is wished for (one
    /// write, two acks), the child is refused: `unavailable` is said.
    @Test(arguments: [false, true]) func anExcessAckEndsTheStream(_ wished: Bool) async throws {
        let ack = AmbientPrivacyEventTests.line("on", sequence: 2, at: 0, extra: #", \"at_ms\": 5"#)
        // Wished for: the reader's own ack follows the pre-sent one, which used the write's credit.
        let fake = try Gate.fake(Self.script(prelude: wished ? "" : "/usr/bin/touch go")
            .replacingOccurrences(of: "exec 4<&0", with: "\(ack)\nexec 4<&0"))
        defer { fake.cleanUp() }
        let seen = Seen()
        let pipeline = try Self.pipeline(fake, seen: seen)
        if wished { #expect(pipeline.reportDuck(true)) }
        let run = Task { try await pipeline.run() }
        if wished {
            #expect(await eventually { Self.control(fake) == "{\"duck\":true}\n" })
            Self.go(fake)
        }
        await #expect(throws: RightyoInputError.invalidEvent) { _ = try await run.value }
        #expect(seen.all == (wished ? [.unavailable] : []))
    }

    /// 4 and 8. No ack within the deadline: the child is killed, `unavailable` is said, the run is refused as
    /// `unacknowledged`, the child heard nothing, and `privacyKept()` answers false.
    @Test func noAckBeforeTheDeadlineRefusesTheChild() async throws {
        let fake = try Gate.fake(Self.script(acks: false))
        defer { fake.cleanUp() }
        let seen = Seen()
        let pipeline = try Self.pipeline(fake, deadline: 0.3, seen: seen)
        #expect(pipeline.reportDuck(true))
        let kept = Task { await pipeline.privacyKept() }
        let run = Task { try await pipeline.run() }
        for _ in 0..<3 { #expect(pipeline.send(audio: Gate.chunk(0x11))) }
        await #expect(throws: RightyoPrivacyRefusal.unacknowledged) { _ = try await run.value }
        #expect(await kept.value == false)
        #expect(seen.all == [.unavailable])
        #expect(Self.control(fake) == "{\"duck\":true}\n")
        #expect(Gate.heard(fake).isEmpty)
    }

    /// 5. Off before the ack lets audio through at once; the late ack for that write is counted, not an error, and
    /// opens nothing.
    @Test func offBeforeTheAck() async throws {
        let fake = try Gate.fake(Self.script())
        defer { fake.cleanUp() }
        let seen = Seen()
        let pipeline = try Self.pipeline(fake, deadline: 0.5, seen: seen)
        #expect(pipeline.reportDuck(true))
        let run = Task { try await pipeline.run() }
        #expect(await eventually { Self.control(fake) == "{\"duck\":true}\n" })
        #expect(pipeline.send(audio: Gate.chunk(0x11)))
        #expect(pipeline.reportDuck(false) && pipeline.hearsAudio)
        #expect(await pipeline.privacyKept() == false)
        #expect(pipeline.send(audio: Gate.chunk(0x33)))
        Self.go(fake)
        // Past the deadline: an off write is never refused for its on's missing ack.
        try await Task.sleep(for: .milliseconds(800))
        pipeline.finishInput()
        _ = try await run.value
        #expect(seen.all.isEmpty)
        #expect(await eventually { Gate.heard(fake).contains(0x33) })
        #expect(!Gate.heard(fake).contains(0x11))
    }

    /// 6. A v2 child keeps nothing but never acks: it is refused for privacy at `started`, fail closed.
    @Test func aVersionTwoChildIsRefusedForPrivacy() async throws {
        let fake = try Gate.fake(Self.script(version: 2))
        defer { fake.cleanUp() }
        let seen = Seen()
        let pipeline = try Self.pipeline(fake, seen: seen)
        #expect(pipeline.reportDuck(true))
        let kept = Task { await pipeline.privacyKept() }
        await #expect(throws: RightyoPrivacyRefusal.unsupportedChild) { _ = try await pipeline.run() }
        #expect(await kept.value == false)
        #expect(seen.all == [.unavailable])
        #expect(Self.control(fake).isEmpty)
    }

    /// 7 and 8. An on while privacy is kept writes nothing and needs no ack; off then on writes again and waits for a
    /// fresh ack. `privacyKept()` answers true once the ack came.
    @Test func aRedundantOnWhileKeptSkipsTheWrite() async throws {
        let fake = try Gate.fake(Self.script())
        defer { fake.cleanUp() }
        let pipeline = try Self.pipeline(fake)
        #expect(pipeline.reportDuck(true))
        let kept = Task { await pipeline.privacyKept() }
        let run = Task { try await pipeline.run() }
        #expect(await eventually { Self.control(fake) == "{\"duck\":true}\n" })
        Self.go(fake)
        #expect(await kept.value)
        #expect(pipeline.hearsAudio && pipeline.reportDuck(true) && pipeline.hearsAudio)
        #expect(await pipeline.privacyKept())
        #expect(pipeline.reportDuck(false) && pipeline.reportDuck(true))
        #expect(await pipeline.privacyKept())
        pipeline.finishInput()
        _ = try await run.value
        #expect(Self.control(fake) == "{\"duck\":true}\n{\"duck\":false}\n{\"duck\":true}\n")
    }
}
#endif
