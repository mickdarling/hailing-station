import AVFAudio
import Foundation
@testable import HailCore
import Testing

/// Manual deadlines and fake buffers exercise recovery without real speech synthesis or its timing (#825).
@MainActor
@Suite struct AnnouncementRendererTests {
    @Test func aHungUtteranceIsStoppedAndTheNextCueUsesAFreshSynthesizer() async throws {
        let box = SpeechBox()
        let renderer = box.renderer()
        let first = Task { try? await renderer.audio(for: .replyAudioLost) }
        await box.awaitDeadlines(1)
        let old = try #require(box.synthesizers.first)
        #expect(old.callbacks.count == 1)
        await box.fireDeadline(0)
        #expect(await first.value == nil, "the unfinished cue falls back")
        #expect(old.stops == [.immediate])
        #expect(box.synthesizers.count == 2)
        old.complete(0) // Late samples and completion must not resume the continuation again (#825).

        let next = Task { try await renderer.audio(for: .replyAudioLost) }
        await box.awaitDeadlines(2)
        let fresh = try #require(box.synthesizers.last)
        #expect(fresh !== old)
        #expect(fresh.callbacks.count == 1)
        fresh.complete(0)
        let audio = try await next.value
        #expect(audio.last?.isFinal == true)
        #expect(audio.first?.bytes == Data([7, 0]))
        await box.fireDeadline(1)
        #expect(fresh.stops.isEmpty, "a completed utterance must not reset the synthesizer")
        #expect(box.synthesizers.count == 2)
    }

    @Test func queuedOldWritesFallBackWithoutStoppingTheReplacement() async throws {
        let box = SpeechBox()
        let renderer = box.renderer()
        let first = Task { try? await renderer.audio(for: .replyAudioLost) }
        await box.awaitDeadlines(1)
        let queued = Task { try? await renderer.audio(for: .replyAudioFailed) }
        await box.awaitDeadlines(2)
        let old = try #require(box.synthesizers.first)
        #expect(old.callbacks.count == 2)
        await box.fireDeadline(0)
        #expect(await first.value == nil)
        let next = Task { try await renderer.audio(for: .replyAudioLost) }
        await box.awaitDeadlines(3)
        let fresh = try #require(box.synthesizers.last)
        await box.fireDeadline(1)
        #expect(await queued.value == nil)
        #expect(box.synthesizers.count == 2, "an old deadline cannot replace the fresh synthesizer")
        #expect(fresh.stops.isEmpty)
        old.complete(1)
        fresh.complete(0)
        #expect(try await next.value.last?.isFinal == true)
        await box.fireDeadline(2)
        #expect(fresh.stops.isEmpty)
    }
}

@MainActor
private final class SpeechBox {
    var synthesizers: [StubSynthesizer] = []
    private var deadlines: [CheckedContinuation<Void, Never>] = []
    private var scheduled: CheckedContinuation<Void, Never>?
    private var finished: CheckedContinuation<Void, Never>?

    func renderer() -> LocalAnnouncementRenderer {
        LocalAnnouncementRenderer(makeSynthesizer: {
            let synthesizer = StubSynthesizer()
            self.synthesizers.append(synthesizer)
            return synthesizer
        }, waitForDeadline: {
            await withCheckedContinuation { continuation in
                self.deadlines.append(continuation)
                self.scheduled?.resume()
                self.scheduled = nil
            }
            // Resumed on this actor after the renderer's deadline handler has run to completion (#825).
            Task { self.finished?.resume(); self.finished = nil }
        })
    }

    func awaitDeadlines(_ count: Int) async {
        while deadlines.count < count {
            await withCheckedContinuation { scheduled = $0 }
        }
    }

    func fireDeadline(_ index: Int) async {
        await withCheckedContinuation {
            finished = $0
            deadlines[index].resume()
        }
    }
}

/// The renderer and tests call this fake synchronously on the main actor; it never starts real synthesis (#825).
private final class StubSynthesizer: AVSpeechSynthesizer {
    var callbacks: [AVSpeechSynthesizer.BufferCallback] = []
    var stops: [AVSpeechBoundary] = []

    override func write(_ utterance: AVSpeechUtterance,
                        toBufferCallback callback: @escaping AVSpeechSynthesizer.BufferCallback) {
        callbacks.append(callback)
    }

    override func stopSpeaking(at boundary: AVSpeechBoundary) -> Bool {
        stops.append(boundary)
        return true
    }

    func complete(_ index: Int) {
        guard let format = AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: 24_000,
                                        channels: 1, interleaved: false),
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1) else {
            Issue.record("Could not create fake speech buffer")
            return
        }
        buffer.frameLength = 1
        buffer.int16ChannelData?.pointee[0] = 7
        callbacks[index](buffer)
        buffer.frameLength = 0
        callbacks[index](buffer)
    }
}
