import AVFAudio
import Foundation
import Testing
@testable import HailCore

/// #269: old stream teardown cannot stop a newer run on the same capture owner. No hardware IO.
@Suite @MainActor struct AudioEngineCaptureRunIdentityTests {
    @Test func preparedTapDoesNotStartIOAndIsReusedByFirstRun() async throws {
        let fake = CountingEngineOperations()
        var installs = 0
        var operations = fake.operations
        let install = operations.installTap
        operations.installTap = { engine, tap in installs += 1; install(engine, tap) }
        let capture = AVAudioEngineCapture(engine: AVAudioEngine(), notificationCenter: NotificationCenter(),
                                           operations: operations)
        try capture.prepareTap()
        #expect(installs == 1 && fake.starts == 0 && !fake.running)
        #expect(throws: AudioCaptureError.alreadyRunning) { try capture.prepareTap() }
        let stream = try capture.start()
        #expect(installs == 1 && fake.starts == 1 && fake.running)
        fake.feed(try sineBuffer())
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() != nil)
        capture.stop()
        #expect(fake.tap == nil && !fake.running)
        let next = try capture.start()
        #expect(installs == 2 && fake.starts == 2)
        capture.stop()
        withExtendedLifetime(next) {}
    }

    @Test func stoppingBeforePreparedRunDropsTheTapAndFinishesItsStream() throws {
        let fake = CountingEngineOperations()
        let capture = AVAudioEngineCapture(engine: AVAudioEngine(), notificationCenter: NotificationCenter(),
                                           operations: fake.operations)
        try capture.prepareTap()
        capture.stop()
        #expect(fake.tap == nil && fake.starts == 0 && !fake.running)
        try capture.prepareTap()
        #expect(fake.tap != nil && fake.starts == 0)
        capture.stop()
    }

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
