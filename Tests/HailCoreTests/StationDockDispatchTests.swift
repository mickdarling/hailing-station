import HailCore
import Testing

@MainActor
struct StationDockDispatchTests {
    @Test func secondFinishAfterAnEmptyRecordingCannotStartCapture() async throws {
        let capture = FakeAudioCapture()
        let playback = ReplyPlaybackController(player: DuplexPlayer())
        let owner = TranscriptionLabView(capture: capture, playback: playback, transcriber: TapLifecycleTranscriber())
        let destination = DestinationControlState.confirmed(
            DestinationLabel(hostName: "Fixture", targetName: "Session", targetKind: "tmux", targetID: "fixture"))
        let accessories = DockAccessories(escape: false, privacy: false, paste: false)
        func dispatch(_ intent: VoiceDockIntent) -> Task<Void, Never>? {
            owner.dispatchDockPrimary(intent, destination: destination, accessories: accessories)
        }

        let start = try #require(dispatch(.talk))
        await start.value
        #expect(owner.isRecording)
        #expect(dispatch(.talk) == nil)
        let finish = try #require(dispatch(.finish))
        await finish.value
        #expect(owner.status == "Nothing heard" && !owner.isRecording)
        let repeated = dispatch(.finish)
        await repeated?.value
        #expect(repeated == nil && owner.startTask == nil)
        #expect(capture.startCount == 1 && !owner.isRecording && owner.sent.isEmpty)
    }
}
