import AVFAudio
import Foundation
import Testing
@testable import HailCore

/// Authored engine operations must own their state until the last capture cleanup callback returns.
@MainActor
@Suite struct FakeEngineOperationsLifetimeTests {
    @Test func callbacksOwnFixtureUntilOperationsAreReleased() throws {
        weak var observed: FakeEngineOperations?
        var operations: AudioEngineOperations?
        do {
            let fake = FakeEngineOperations()
            observed = fake
            operations = fake.operations
        }
        try #require(observed != nil)
        let engine = AVAudioEngine()
        operations?.installTap(engine, { _, _ in })
        #expect(observed?.tap != nil)
        try operations?.start(engine)
        #expect(operations?.isRunning(engine) == true)
        operations?.removeTap(engine)
        operations?.stop(engine)
        #expect(observed?.tap == nil)
        #expect(operations?.isRunning(engine) == false)
        operations = nil
        #expect(observed == nil)
    }

    @Test func retainedCaptureCanStopAfterFixtureScopeEnds() throws {
        weak var observed: FakeEngineOperations?
        var capture: AVAudioEngineCapture?
        do {
            let fake = FakeEngineOperations()
            observed = fake
            capture = AVAudioEngineCapture(engine: AVAudioEngine(), notificationCenter: NotificationCenter(),
                                           operations: fake.operations)
        }
        try #require(observed != nil)
        let stream = try #require(capture).start()
        #expect(observed?.running == true)
        capture?.stop()
        capture?.stop() // Late pump cleanup is allowed after an earlier system stop.
        #expect(observed?.running == false)
        #expect(observed?.tap == nil)
        capture = nil
        withExtendedLifetime(stream) {}
        #expect(observed == nil)
    }
}
