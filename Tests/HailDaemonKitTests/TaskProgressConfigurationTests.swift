import Testing
@testable import HailDaemonKit

struct TaskProgressConfigurationTests {
    private let base = ["--bind", "127.0.0.1", "--port", "9000", "--personal-terminal"]

    @Test func deadlinesAndSpeechAreExplicitIndependentOptIns() throws {
        let plain = try ConnectionProbeDaemon.options(base)
        #expect(!plain.taskProgress && !plain.sessionUpdates && plain.sessionUpdateSpeechRoot == nil)
        let updates = try ConnectionProbeDaemon.options(base + ["--session-updates"])
        #expect(!updates.taskProgress && updates.sessionUpdateSpeechRoot == nil)
        let task = try ConnectionProbeDaemon.options(base + ["--session-updates", "--task-progress"])
        #expect(task.taskProgress && task.sessionUpdates && task.sessionUpdateSpeechRoot == nil)
        let speech = try ConnectionProbeDaemon.options(base + ["--session-updates",
                                                               "--session-update-speech-root", "/synthetic-root"])
        #expect(speech.sessionUpdateSpeechRoot?.path == "/synthetic-root" && !speech.taskProgress)
    }

    @Test func unsupportedCombinationsAndDuplicateSpeechRootsFailClosed() {
        let invalid = [
            base + ["--task-progress"],
            base + ["--session-update-speech-root", "/synthetic-root"],
            base + ["--session-updates", "--session-update-speech-root", "relative"],
            base + ["--session-updates", "--session-update-speech-root", "/a", "--session-update-speech-root", "/b"],
            ["--bind", "127.0.0.1", "--port", "9000", "--connection-probe", "--session-updates", "--task-progress"]
        ]
        for arguments in invalid {
            #expect(throws: WebSocketListenerError.invalidArguments) { try ConnectionProbeDaemon.options(arguments) }
        }
    }
}
