#if os(macOS)
import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

/// Duck cues through the listener (#735 H-3): the owner enters duck mode, thinks aloud, discards, thinks again and
/// asks. The discard is confirmed from `confirm-discarded/`, the ask reaches the selected session once through the
/// listener's own dispatch (sanitizer, guard, policy), only the second thought is sent, and the log carries counts
/// only. Synthetic only.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientDuckCueWiringTests {
    static let duckOn = AmbientAckClip(pcm: Data(repeating: 9, count: 480), sampleRate: 24_000,
                                       text: "Duck mode is on.")
    static let discarded = AmbientAckClip(pcm: Data(repeating: 7, count: 480), sampleRate: 24_000,
                                          text: "Discarded.")
    static let clips = AmbientAckLibrary(clips: ["confirmduckon": [duckOn], "confirmdiscarded": [discarded]])

    /// The entry fixture (H-2's), then `words` as the owner's transcripts while ducking, then `stopped`.
    static func script(_ words: [String]) throws -> String {
        let lines = try words.enumerated().map { try AmbientDuckBufferTests.transcript($0.element,
                                                                                        sequence: $0.offset + 7) }
        let started = #"-e 's/"phase": "started"/"addressing": {"names": ["Rightyo"]}, "duck": {"version": 1}, "#
            + #""phase": "started"/'"#
        return """
        /bin/cat <&3 > control.txt &
        /usr/bin/sed -e '$d' -e "s/formed-demo/$7/g" -e 's/Rightyo, archive the project./Rightyo, duck mode./g' \
          \(started) events.jsonl
        /usr/bin/sed -e "s/formed-demo/$7/g" <<'DUCK'
        \(lines.joined(separator: "\n"))
        DUCK
        /bin/cat > /dev/null
        /usr/bin/sed -n -e '$p' events.jsonl | /usr/bin/sed -e "s/formed-demo/$7/g" \
          -e 's/"sequence": 7/"sequence": 99/' -e 's/"emitted_at_ms": 2000/"emitted_at_ms": 9000/'
        """
    }

    @Test func discardIsConfirmedAndTheAskReachesTheSessionOnce() async throws {
        let script = try Self.script(["First synthetic thought.", "Rightyo, discard that.",
                                      "Second synthetic thought.", "What do you think?"])
        let rig = try await DuckRig(script: script, clips: Self.clips)
        defer { rig.close() }
        var heard: [String] = []
        for _ in 0..<6 where heard.count < 2 {
            let frame = try await receiveFrame(on: rig.socket, step: "duck confirmations")
            if case .text(let words) = frame.payload { heard.append(words.text) }
        }
        #expect(Set(heard) == ["Duck mode is on.", "Discarded."])
        // One delivery through the listener's own dispatch; the prompt's content is checked in AmbientDuckBufferTests.
        #expect(await eventually { await rig.env.rig.adapter.contexts.count == 1 })
        #expect(await eventually { rig.details("ambient_duck_cue").count == 2 })
        await rig.finish()
        let bytes = "Second synthetic thought.".utf8.count
        #expect(rig.details("ambient_duck_cue") == ["cue=discard turns=1 confirm=confirmdiscarded/0:sent",
                                                    "cue=ask outcome=sent turns=1 bytes=\(bytes) confirm=none"])
        // Duck mode itself behaved as H-2 left it: on once, by voice, and the child told.
        #expect(rig.details("ambient_duck").first == "on=true reason=voice reported=1")
        #expect(try rig.fake.recorded("control.txt").hasPrefix("{\"duck\":true}\n"))
        // No log line carries the owner's words.
        let all = ["ambient_duck_cue", "ambient_duck", "ambient_duck_confirmed"].flatMap(rig.details)
        #expect(!all.contains { $0.contains("synthetic") || $0.contains("think") })
    }
}
#endif
