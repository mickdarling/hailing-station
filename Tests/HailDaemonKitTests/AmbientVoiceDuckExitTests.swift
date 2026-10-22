#if os(macOS)
import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit

/// The owner's duck mode exit from the transcript alone (#735 H-2): under rightyo R-2 a ducking RightyO sends the
/// owner's turn as a transcript, with no attention record and no request. Only a live, non-echo owner turn on an
/// enrolled session exits. Synthetic only.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientVoiceDuckExitTests {
    /// `started` (naming `Rightyo` and advertising `duck`) and the owner's transcript of `words`, then `stopped`:
    /// nothing is decided and no request is sent.
    static func transcriptOnly(saying words: String) -> String {
        let started = #"-e 's/"phase": "started"/"addressing": {"names": ["Rightyo"]}, "duck": {"version": 1}, "#
            + #""phase": "started"/'"#
        return """
        /usr/bin/sed -n -e '1p' -e '4p' events.jsonl | /usr/bin/sed -e "s/formed-demo/$7/g" \
          -e 's/Rightyo, archive the project./\(words)/g' \(started)
        /bin/cat > /dev/null
        /usr/bin/sed -n -e '$p' events.jsonl | /usr/bin/sed "s/formed-demo/$7/g"
        """
    }

    private func run(_ words: String, allowSynthetic: Bool = true, ducking: Bool = true,
                     isEcho: (@Sendable (String) -> Bool)? = nil) async throws -> ([VoiceDuckCommand], Int) {
        let fake = try FakeRightyo(Self.transcriptOnly(saying: words))
        defer { fake.cleanUp() }
        try fake.install(fixture: "enrolled-formed-request.jsonl")
        let seen = Mutex<[VoiceDuckCommand]>([])
        var configuration = RightyoAmbientPipeline.Configuration(
            executable: fake.executable, config: fake.config, target: "tmux:demo", binding: "pinned",
            connection: UUID(), allowSynthetic: allowSynthetic, timing: .init(eofGrace: 20, termGrace: 20),
            isEcho: isEcho
        )
        configuration.onVoiceDuck = { command in seen.withLock { $0.append(command) } }
        configuration.replyControl = true
        let dispatcher = RecordingAmbientDispatcher()
        let pipeline = try RightyoAmbientPipeline(configuration: configuration, dispatcher: dispatcher)
        if ducking { pipeline.reportDuck(true) }
        pipeline.finishInput()
        let delivered = try await pipeline.run().delivered
        return (seen.withLock { $0 }, delivered)
    }

    @Test func theOwnersTranscriptAloneExitsOnce() async throws {
        let (seen, delivered) = try await run("Rightyo, done thinking.")
        #expect(seen == [.off] && delivered == 0)
    }

    /// Outside duck mode the owner's transcript is only a transcript.
    @Test func outsideDuckModeTheTranscriptDoesNotExit() async throws {
        let (seen, _) = try await run("Rightyo, done thinking.", ducking: false)
        #expect(seen.isEmpty)
    }

    /// An entry is never taken from a transcript: only a request the owner's attention record confirmed enters.
    @Test func aTranscriptNeverEnters() async throws {
        let (seen, _) = try await run("Rightyo, duck mode.")
        #expect(seen.isEmpty)
    }

    /// The assistant's own words heard back are never the owner's exit.
    @Test func anEchoedExitDoesNotExit() async throws {
        let (seen, _) = try await run("Rightyo, done thinking.", isEcho: { $0.contains("done thinking") })
        #expect(seen.isEmpty)
    }

    /// A turn not from the live microphone (the fixture's `synthetic` provenance, with synthetic turns not admitted)
    /// never exits.
    @Test func aNonLiveExitDoesNotExit() async throws {
        let (seen, _) = try await run("Rightyo, done thinking.", allowSynthetic: false)
        #expect(seen.isEmpty)
    }
}
#endif
