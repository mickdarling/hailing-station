import AVFAudio
import Foundation
import Testing
@testable import HailCore

/// #269: old stream teardown cannot stop a newer run on the same capture owner. No hardware IO.
@Suite @MainActor struct AudioEngineCaptureRunIdentityTests {
    @Test func stoppedStreamsCannotRetireImmediateReplacement() async throws {
        let fake = CountingEngineOperations()
        let capture = AVAudioEngineCapture(engine: AVAudioEngine(), notificationCenter: NotificationCenter(),
                                           operations: fake.operations)
        let old = try capture.start()
        capture.stop()
        let fresh = try capture.start()
        await drainCoachingTasks()
        #expect(fake.starts == 2 && fake.stops == 1 && fake.running && fake.tap != nil)
        fake.feed(try sineBuffer())
        var iterator = fresh.makeAsyncIterator()
        #expect(await iterator.next() != nil)
        capture.stop()
        withExtendedLifetime(old) {}
    }

    @Test func cancelledOldConsumerCannotRetireImmediateReplacement() async throws {
        let fake = CountingEngineOperations()
        let capture = AVAudioEngineCapture(engine: AVAudioEngine(), notificationCenter: NotificationCenter(),
                                           operations: fake.operations)
        let old = try capture.start()
        let consumer = Task { @MainActor in
            for await _ in old { }
        }
        await drainCoachingTasks()
        consumer.cancel()
        capture.stop()
        let fresh = try capture.start()
        await consumer.value
        await drainCoachingTasks()
        #expect(fake.starts == 2 && fake.stops == 1 && fake.running && fake.tap != nil)
        capture.stop()
        withExtendedLifetime(fresh) {}
    }

    @Test func currentConsumerCancellationStillRetiresItsOwnedRun() async throws {
        let fake = CountingEngineOperations()
        let capture = AVAudioEngineCapture(engine: AVAudioEngine(), notificationCenter: NotificationCenter(),
                                           operations: fake.operations)
        let stream = try capture.start()
        let consumer = Task { @MainActor in
            for await _ in stream { }
        }
        await drainCoachingTasks()
        consumer.cancel()
        await consumer.value
        await drainCoachingTasks()
        #expect(!fake.running && fake.tap == nil && fake.stops == 1)
    }
}
