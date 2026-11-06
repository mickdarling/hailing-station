import Testing
@testable import HailDaemonKit

@Suite struct TaskProgressVoiceControlTests {
    @Test func exactOwnerCommandsShareTheTypedControlSurface() {
        #expect(TaskProgressOwnerControl.parse("progress updates more often") == .moreOften)
        #expect(TaskProgressOwnerControl.parse("updates less often") == .lessOften)
        #expect(TaskProgressOwnerControl.parse("pause updates") == .pause)
        #expect(TaskProgressOwnerControl.parse("resume progress updates") == .resume)
        #expect(TaskProgressOwnerControl.parse("stop updates") == .stop)
        #expect(TaskProgressOwnerControl.parse("  Progress updates every 2 minutes  ") == .interval(.seconds(120)))
        #expect(TaskProgressOwnerControl.parse("progress updates every 1 hour") == .interval(.seconds(3_600)))
        #expect(TaskProgressOwnerControl.parse("progress updates every 15 seconds") == .interval(.seconds(15)))
    }

    @Test(arguments: [
        "someone said pause updates", "pause updates and restart", "stop recording", "stop",
        "progress updates every 0 minutes", "progress updates every -1 seconds", "progress updates every 5 seconds",
        "progress updates every 61 minutes", "progress updates every 9223372036854775807 hours",
        "progress updates every NaN seconds", "progress updates every 2 minutes then recover the session"
    ])
    func unrelatedQuotedInvalidAndCompoundRequestsDoNotChangeSettings(_ text: String) {
        #expect(TaskProgressOwnerControl.parse(text) == nil)
    }
}
