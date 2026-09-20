import AVFAudio
import Testing
@testable import HailCore

@Suite struct CaptureSmokeTests {
    @Test func fakeTriggerReplaysScriptedEvents() async {
        let trigger = FakeTrigger([.utteranceStarted, .utteranceFinal("hello"), .cancelled])
        var seen: [TriggerEvent] = []
        for await event in trigger.events { seen.append(event) }
        #expect(seen == [.utteranceStarted, .utteranceFinal("hello"), .cancelled])
    }

    @Test func transcriptionResultEquality() {
        #expect(TranscriptionResult(text: "a", isFinal: true) == TranscriptionResult(text: "a", isFinal: true))
        #expect(TranscriptionResult(text: "a", isFinal: true) != TranscriptionResult(text: "a", isFinal: false))
    }

    @Test func ownedCaptureBufferDoesNotAliasTheEngineBuffer() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let source = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1))
        source.frameLength = 1
        source.floatChannelData?[0][0] = 0.25

        let owned = try #require(AudioCaptureBuffer(copying: source))
        source.floatChannelData?[0][0] = 0.75

        #expect(owned.pcmBuffer.floatChannelData?[0][0] == 0.25)
    }

    @Test func fakeTranscriberAcceptsOwnedCaptureBuffers() async throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let source = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1))
        source.frameLength = 1
        let owned = try #require(AudioCaptureBuffer(copying: source))
        let transcriber = FakeTranscriber()

        await transcriber.start()
        await transcriber.consume(owned)
        await transcriber.stop()

        #expect(await transcriber.consumedBuffers == 1)
        #expect(await !transcriber.isRunning)
    }
}
