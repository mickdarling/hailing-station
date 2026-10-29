#if os(macOS)
import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit

/// Fake child through real consumer/pipeline admission; no microphone, provider or playback.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientTaskProgressVoiceTests {
    private struct Case: Sendable {
        var enrolled = true
        var guest = false
        var roleSource: String? = "voiceprint"
        var live = true
        var echo = false
        var wired = true
        var accepted = true
    }

    private func run(_ test: Case, words: String = "pause updates") async throws -> ([TaskProgressOwnerControl], Int) {
        var script = AmbientPrivacyEntryTests.fixture(saying: words, enrolled: test.enrolled,
                                                      guest: test.guest, roleSource: test.roleSource)
        if test.live {
            script = script.replacingOccurrences(of: "-e '$d'", with:
                #"-e '$d' -e 's/synthetic/live-microphone/g'"#)
        }
        let fake = try FakeRightyo(script)
        defer { fake.cleanUp() }
        try fake.install(fixture: test.enrolled ? "enrolled-formed-request.jsonl" : "tool-events.jsonl")
        let seen = Mutex<[TaskProgressOwnerControl]>([])
        var config = RightyoAmbientPipeline.Configuration(
            executable: fake.executable, config: fake.config, target: "tmux:demo", binding: "pinned",
            connection: UUID(), allowSynthetic: true, timing: .init(eofGrace: 20, termGrace: 20),
            isEcho: { _ in test.echo }
        )
        if test.wired {
            config.onTaskProgressOwner = { command in
                seen.withLock { $0.append(command) }
                return test.accepted
            }
        }
        let pipeline = try RightyoAmbientPipeline(configuration: config, dispatcher: RecordingAmbientDispatcher())
        pipeline.finishInput()
        let delivered = try await pipeline.run().delivered
        return (seen.withLock { $0 }, delivered)
    }

    @Test func exactLiveOwnerCommandUsesHostCallbackInsteadOfTyping() async throws {
        let (commands, delivered) = try await run(Case())
        #expect(commands == [.pause])
        #expect(delivered == 0)
        var test = Case()
        test.roleSource = "voiceprint_label"
        let inferred = try await run(test, words: "Rightyo, progress updates every 2 minutes.")
        #expect(inferred.0 == [.interval(.seconds(120))] && inferred.1 == 0)
    }

    @Test func roleOnlyGuestAnonymousAndSyntheticCannotChangeOwnerCadence() async throws {
        var cases = [Case]()
        var value = Case(); value.roleSource = "label"; cases.append(value)
        value = Case(); value.roleSource = nil; cases.append(value)
        value = Case(); value.guest = true; cases.append(value)
        value = Case(); value.enrolled = false; cases.append(value)
        value = Case(); value.live = false; cases.append(value)
        for test in cases {
            let (commands, delivered) = try await run(test)
            #expect(commands.isEmpty)
            #expect(delivered == 1)
        }
    }

    @Test func echoCannotReachHookAndCompoundTextStaysARequest() async throws {
        var test = Case()
        test.echo = true
        let echo = try await run(test)
        #expect(echo.0.isEmpty && echo.1 == 0)
        let compound = try await run(Case(), words: "pause updates and restart")
        #expect(compound.0.isEmpty && compound.1 == 1)
    }

    @Test func disabledOrNoActiveMatchingTaskDoesNotSwallowCommand() async throws {
        var test = Case()
        test.wired = false
        let disabled = try await run(test)
        #expect(disabled.0.isEmpty && disabled.1 == 1)
        test.wired = true
        test.accepted = false
        let noTask = try await run(test)
        #expect(noTask.0 == [.pause] && noTask.1 == 1)
    }
}
#endif
