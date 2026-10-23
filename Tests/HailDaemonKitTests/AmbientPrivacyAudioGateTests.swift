#if os(macOS)
import Foundation
import Testing
@testable import HailDaemonKit

/// Privacy's audio gate (#735 S-2b round 3): while privacy is wished for, a child hears no audio until it has shown it
/// keeps privacy (a start-private `started` confirming `private`, or a v3 child's ack of `{"duck":true}`). Dropped
/// chunks never reach the child; a child that cannot keep privacy, or never starts, is killed having heard none.
/// Synthetic only: the fake records every byte it reads to `audio.raw`.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientPrivacyAudioGateTests {
    /// `started` after `delay` (advertising `duck` v3 when asked, and `private` when launched start-private), then
    /// every stdin byte to `audio.raw`, then `stopped`; or, with `starts` false, only the recording. Control lines go
    /// to `control.txt`, and each `{"duck":true}` is acked once `started` is out (#735 S-8).
    static func script(advertises: Bool, delay: String = "0.5", starts: Bool = true) -> String {
        let duck = advertises ? FakeRightyo.duckV3 : ""
        guard starts else { return "/bin/cat > audio.raw" }
        return """
        \(AmbientPrivacyEntryTests.startPrivatePrelude)
        \(FakeRightyo.ackingControl())
        /bin/sleep \(delay)
        /usr/bin/sed -n -e '1p' events.jsonl | /usr/bin/sed -e "s/formed-demo/$7/g"\(duck)
        \(FakeRightyo.acksMayFollow)
        /bin/cat > audio.raw
        wait
        /usr/bin/sed -n -e '$p' events.jsonl | /usr/bin/sed -e "s/formed-demo/$7/g"\(FakeRightyo.lastSequence)
        """
    }

    static func chunk(_ byte: UInt8) -> Data { Data(repeating: byte, count: 480) }

    /// Every byte the child read, or none.
    static func heard(_ fake: FakeRightyo) -> Data {
        (try? Data(contentsOf: fake.directory.appendingPathComponent("audio.raw"))) ?? Data()
    }

    static func pipeline(_ fake: FakeRightyo, startPrivate: Bool, deadline: TimeInterval = 10,
                         unsupported: (@Sendable () -> Bool)? = nil) throws -> RightyoAmbientPipeline {
        var configuration = RightyoAmbientPipeline.Configuration(
            executable: fake.executable, config: fake.config, target: "tmux:demo", binding: "pinned",
            connection: UUID(), allowSynthetic: true, timing: .init(eofGrace: 20, termGrace: 20)
        )
        (configuration.replyControl, configuration.startPrivate) = (true, startPrivate)
        (configuration.onVoiceDuck, configuration.startDeadline) = ({ _ in }, deadline)
        configuration.onDuckUnsupported = unsupported
        return try RightyoAmbientPipeline(configuration: configuration, dispatcher: RecordingAmbientDispatcher())
    }

    static func fake(_ script: String) throws -> FakeRightyo {
        let fake = try FakeRightyo(script)
        try fake.install(fixture: "enrolled-formed-request.jsonl")
        return fake
    }

    /// Entry while a public child is starting: nothing before its `started`; a v3 child then takes privacy and hears
    /// what follows once it acks (it keeps nothing), a child without v3 is killed. Either way, no private audio before
    /// the proof.
    @Test(arguments: [true, false]) func anEntryWhileAChildStartsWithholdsAudio(_ advertises: Bool) async throws {
        let fake = try Self.fake(Self.script(advertises: advertises))
        defer { fake.cleanUp() }
        let pipeline = try Self.pipeline(fake, startPrivate: false)
        #expect(pipeline.reportDuck(true) && !pipeline.hearsAudio)
        let run = Task { try await pipeline.run() }
        for _ in 0..<3 { #expect(pipeline.send(audio: Self.chunk(0x11))) }
        if advertises {
            #expect(await eventually { pipeline.hearsAudio })
            #expect(pipeline.send(audio: Self.chunk(0x22)))
            pipeline.finishInput()
            _ = try await run.value
            #expect(await eventually { Self.heard(fake).contains(0x22) })
        } else {
            await #expect(throws: RightyoPrivacyRefusal.unsupportedChild) { _ = try await run.value }
        }
        #expect(!Self.heard(fake).contains(0x11))
    }

    /// A start-private respawn hears nothing before its `started` confirms `private`.
    @Test func aStartPrivateChildHearsNothingBeforeItsConfirm() async throws {
        let fake = try Self.fake(Self.script(advertises: true))
        defer { fake.cleanUp() }
        let pipeline = try Self.pipeline(fake, startPrivate: true)
        #expect(!pipeline.hearsAudio)
        let run = Task { try await pipeline.run() }
        for _ in 0..<3 { #expect(pipeline.send(audio: Self.chunk(0x11))) }
        #expect(await eventually { pipeline.hearsAudio })
        #expect(pipeline.send(audio: Self.chunk(0x22)))
        pipeline.finishInput()
        _ = try await run.value
        #expect(await eventually { Self.heard(fake).contains(0x22) })
        #expect(!Self.heard(fake).contains(0x11))
    }

    /// Privacy that ends before the confirm lets audio through again at once.
    @Test func privacyEndingBeforeTheConfirmResumesAudio() async throws {
        let fake = try Self.fake(Self.script(advertises: true))
        defer { fake.cleanUp() }
        let pipeline = try Self.pipeline(fake, startPrivate: true)
        let run = Task { try await pipeline.run() }
        #expect(pipeline.send(audio: Self.chunk(0x11)))
        _ = pipeline.reportDuck(false)
        #expect(pipeline.hearsAudio)
        #expect(pipeline.send(audio: Self.chunk(0x33)))
        pipeline.finishInput()
        _ = try await run.value
        #expect(await eventually { Self.heard(fake).contains(0x33) })
        #expect(!Self.heard(fake).contains(0x11))
    }

    /// A child that never starts while privacy is wished for (entry while it was starting) hears nothing and is
    /// killed at the deadline.
    @Test func aChildThatHangsHearsNothingAndIsKilled() async throws {
        let fake = try Self.fake(Self.script(advertises: true, starts: false))
        defer { fake.cleanUp() }
        let pipeline = try Self.pipeline(fake, startPrivate: false, deadline: 0.3)
        #expect(pipeline.reportDuck(true))
        let run = Task { try await pipeline.run() }
        for _ in 0..<3 { #expect(pipeline.send(audio: Self.chunk(0x11))) }
        await #expect(throws: RightyoPrivacyRefusal.unconfirmedStart) { _ = try await run.value }
        #expect(Self.heard(fake).isEmpty)
    }

    /// M18d: with no `onDuckUnsupported` handler, a child without v3 is refused (fail closed).
    @Test func withoutAHandlerTheChildIsRefused() async throws {
        let fake = try Self.fake(Self.script(advertises: false, delay: "0"))
        defer { fake.cleanUp() }
        let pipeline = try Self.pipeline(fake, startPrivate: false)
        #expect(pipeline.reportDuck(true))
        await #expect(throws: RightyoPrivacyRefusal.unsupportedChild) { _ = try await pipeline.run() }
    }

    /// M18f: when the host says privacy already ended, a child without v3 runs on, public, and hears audio again.
    @Test func whenPrivacyAlreadyEndedTheChildRunsOn() async throws {
        let fake = try Self.fake(Self.script(advertises: false))
        defer { fake.cleanUp() }
        let pipeline = try Self.pipeline(fake, startPrivate: false, unsupported: { false })
        #expect(pipeline.reportDuck(true))
        let run = Task { try await pipeline.run() }
        #expect(pipeline.send(audio: Self.chunk(0x11)))
        #expect(await eventually { pipeline.hearsAudio })
        #expect(pipeline.send(audio: Self.chunk(0x44)))
        pipeline.finishInput()
        _ = try await run.value
        #expect(await eventually { Self.heard(fake).contains(0x44) })
        #expect(!Self.heard(fake).contains(0x11))
    }
}
#endif
