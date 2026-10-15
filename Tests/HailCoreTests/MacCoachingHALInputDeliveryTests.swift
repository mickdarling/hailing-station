#if os(macOS)
import AudioToolbox
import AVFAudio
import Synchronization
import Testing
@testable import HailCore

@Suite(.timeLimit(.minutes(1))) @MainActor struct MacCoachingHALInputDeliveryTests {
    @Test func ownsCopiedPCMAndRetirementRejectsLaterCallbacks() async throws {
        let storage = HALAuthoredBuffer()
        let delivery = try makeDelivery { _, _, _, buffer in
            storage.buffer = buffer
            buffer.floatChannelData?[0][0] = 0.25
            return noErr
        }
        let pair = AsyncStream<AudioCaptureBuffer>.makeStream(bufferingPolicy: .bufferingOldest(2))
        #expect(delivery.arm(pair.continuation))
        #expect(render(delivery) == noErr)
        storage.buffer?.floatChannelData?[0][0] = 0.75
        delivery.retire()
        #expect(render(delivery) == noErr)
        var iterator = pair.stream.makeAsyncIterator()
        let snapshot = await iterator.next()
        #expect(snapshot?.pcmBuffer.floatChannelData?[0][0] == 0.25)
        #expect(await iterator.next() == nil)
        #expect(!delivery.healthy && !delivery.arm(pair.continuation))
    }

    @Test func boundedOverflowRetiresRatherThanDroppingAndContinuing() async throws {
        let calls = Mutex(0)
        let delivery = try makeDelivery { _, _, _, _ in calls.withLock { $0 += 1 }; return noErr }
        let pair = AsyncStream<AudioCaptureBuffer>.makeStream(bufferingPolicy: .bufferingOldest(2))
        #expect(delivery.arm(pair.continuation))
        for _ in 0..<4 { #expect(render(delivery) == noErr) }
        #expect(!delivery.healthy && calls.withLock { $0 } == 3)
        var received = 0
        for await _ in pair.stream { received += 1 }
        #expect(received == 2)
    }

    @Test func revocationDuringPullCannotPublishItsCompletedBuffer() async throws {
        let holder = Mutex<MacCoachingHALInputDelivery?>(nil)
        let delivery = try makeDelivery { _, _, _, _ in holder.withLock { $0 }?.retire(); return noErr }
        holder.withLock { $0 = delivery }
        let pair = AsyncStream<AudioCaptureBuffer>.makeStream(bufferingPolicy: .bufferingOldest(2))
        #expect(delivery.arm(pair.continuation))
        #expect(render(delivery) == noErr)
        holder.withLock { $0 = nil }
        var iterator = pair.stream.makeAsyncIterator()
        #expect(await iterator.next() == nil)
        #expect(!delivery.healthy)
    }

    @Test func invalidFrameExtentFailsBeforePullAndRenderErrorPublishesNothing() async throws {
        for invalid in [true, false] {
            let calls = Mutex(0)
            let delivery = try makeDelivery { _, _, _, _ in calls.withLock { $0 += 1 }; return kAudio_ParamError }
            let pair = AsyncStream<AudioCaptureBuffer>.makeStream(bufferingPolicy: .bufferingOldest(2))
            #expect(delivery.arm(pair.continuation))
            #expect(render(delivery, frames: invalid ? 8_193 : 160) == kAudio_ParamError)
            #expect(calls.withLock { $0 } == (invalid ? 0 : 1))
            var iterator = pair.stream.makeAsyncIterator()
            #expect(await iterator.next() == nil)
            #expect(!delivery.healthy)
        }
    }

    private func makeDelivery(_ pull: @escaping MacCoachingHALInputDelivery.Pull) throws
        -> MacCoachingHALInputDelivery {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        return MacCoachingHALInputDelivery(format: format, pull: pull)
    }
    private func render(_ delivery: MacCoachingHALInputDelivery, frames: UInt32 = 160) -> OSStatus {
        var flags = AudioUnitRenderActionFlags(), timestamp = AudioTimeStamp()
        return delivery.render(&flags, time: &timestamp, frames: frames)
    }
}

private final class HALAuthoredBuffer: @unchecked Sendable {
    // Only the test's synchronous injected pull and its subsequent caller access this authored buffer.
    var buffer: AVAudioPCMBuffer?
}
#endif
