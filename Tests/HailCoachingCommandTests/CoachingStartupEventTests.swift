import Foundation
@testable import HailCore
import HailDaemonKit
import Testing
@testable import haild

@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor struct CoachingStartupEventTests {
    @Test(arguments: ["-1", "0.5", "true", "0", "0.0"])
    func malformedStartupTimeCannotUnlockAdvice(emitted: String) async throws {
        let root = TestScratch.url("coaching-event")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        let executable = root.appendingPathComponent("authored-child"), config = root.appendingPathComponent("config")
        let script = """
        #!/bin/sh
        session=''
        while [ "$#" -gt 0 ]; do
          if [ "$1" = '--session-id' ]; then shift; session="$1"; fi
          shift
        done
        printf '{"schema_version":1,"type":"session","phase":"started","session_id":"%s",\
        "sequence":1,"emitted_at_ms":\(emitted)}\\n' "$session"
        printf '{"schema_version":1,"type":"coaching_advice"}\\n'
        exec /bin/cat
        """
        try Data(script.utf8).write(to: executable)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: executable.path)
        try Data("{}".utf8).write(to: config)
        let profile = Data("""
        {"version":1,"listener_id":"coach","name":"Coach","domain":"Authored","speak_when":"Pause",\
        "stay_quiet_when":"Busy","delivery":"owner_private","priority":0,"cooldown_ms":0}
        """.utf8)
        var advice = 0, ended = 0
        let transport = try CoachingChildTransport(.init(executable: executable, config: config, profile: profile,
            listenerID: "coach", provenance: .synthetic, mockSuggestions: nil),
            hooks: .init(advice: { _ in advice += 1 }, ended: { ended += 1 }), activityFlags: { nil })
        do {
            try #require(transport.send(.enable(sessionID: UUID(), destinationID: UUID(), listenerID: "coach")))
            let deadline = ContinuousClock.now.advanced(by: .seconds(2))
            while advice == 0, ended == 0, ContinuousClock.now < deadline {
                try await Task.sleep(for: .milliseconds(10))
            }
            let valid = emitted == "0" || emitted == "0.0"
            #expect(advice == (valid ? 1 : 0))
            #expect(ended == (valid ? 0 : 1))
        } catch { await transport.stop(); throw error }
        await transport.stop()
    }
}
