import AVFAudio
import Foundation
import HailProtocol
import Testing
@testable import HailCore

/// #443: an ambient engine that stays "running" but stops delivering buffers is restarted in place, on the same
/// stream, and reported; repeated stalls, or a restart that fails, end the run as `endedBySystem`.
@MainActor
@Suite struct AudioEngineCaptureStallTests {
    let center = NotificationCenter()
    let fake = CountingEngineOperations()
    let sleeper = SteppedSleeper()
    static let policy = AVAudioEngineCapture.StallPolicy(limit: .seconds(5), check: .seconds(1), maxRestarts: 2)

    func capture() -> AVAudioEngineCapture {
        let sleeper = sleeper
        return AVAudioEngineCapture(
            engine: AVAudioEngine(), notificationCenter: center, operations: fake.operations,
            stallPolicy: Self.policy, now: { sleeper.clock.now() }, sleep: { try await sleeper.sleep($0) }
        )
    }

    /// Advances one check interval and waits until the watchdog has slept again, or has ended.
    func step(_ capture: AVAudioEngineCapture, notes: PostedNotes) async throws {
        try await waitUntil { [sleeper] in sleeper.isWaiting }
        sleeper.tick()
        let ended = AVAudioEngineCapture.endedBySystem
        try await waitUntil { [sleeper] in sleeper.isWaiting || !notes.named(ended).isEmpty }
    }

    @Test func buffersArrivingKeepTheEngineAlone() async throws {
        let notes = PostedNotes(center, [AVAudioEngineCapture.stalled])
        let capture = capture()
        let stream = try capture.start()
        for _ in 0..<12 {
            fake.feed(try sineBuffer())
            try await step(capture, notes: notes)
        }
        #expect(notes.named(AVAudioEngineCapture.stalled).isEmpty)
        #expect(fake.starts == 1)
        capture.stop()
        withExtendedLifetime(stream) {}
    }

    @Test func aStalledEngineRestartsOnTheSameStreamAndIsReported() async throws {
        let notes = PostedNotes(center, [AVAudioEngineCapture.stalled, AVAudioEngineCapture.endedBySystem])
        let capture = capture()
        let stream = try capture.start()
        for _ in 0..<4 { try await step(capture, notes: notes) }
        #expect(notes.named(AVAudioEngineCapture.stalled).isEmpty, "four quiet seconds are not yet a stall")
        try await step(capture, notes: notes)

        let stalls = notes.named(AVAudioEngineCapture.stalled)
        #expect(stalls.count == 1)
        #expect(stalls.first?.userInfo?[AVAudioEngineCapture.restartAttemptKey] as? UInt == 1)
        #expect(stalls.first?.userInfo?[AVAudioEngineCapture.stalledMillisecondsKey] as? UInt == 5_000)
        #expect(fake.starts == 2 && fake.stops == 1 && fake.running && fake.tap != nil)
        #expect(notes.named(AVAudioEngineCapture.endedBySystem).isEmpty)

        // The restarted engine feeds the same stream the consumer already holds.
        var iterator = stream.makeAsyncIterator()
        fake.feed(try sineBuffer())
        #expect(await iterator.next() != nil)
        capture.stop()
    }

    @Test func aBufferAfterARestartEarnsAFreshSetOfRestarts() async throws {
        let notes = PostedNotes(center, [AVAudioEngineCapture.stalled, AVAudioEngineCapture.endedBySystem])
        let capture = capture()
        let stream = try capture.start()
        for round in 0..<3 {
            // After the first, the check that sees the fed buffer resets the clock, so five quiet ones follow it.
            for _ in 0..<(round == 0 ? 5 : 6) { try await step(capture, notes: notes) }
            fake.feed(try sineBuffer())
        }
        let attempts = notes.named(AVAudioEngineCapture.stalled).map {
            $0.userInfo?[AVAudioEngineCapture.restartAttemptKey] as? UInt
        }
        #expect(attempts == [1, 1, 1])
        #expect(notes.named(AVAudioEngineCapture.endedBySystem).isEmpty)
        capture.stop()
        withExtendedLifetime(stream) {}
    }

    @Test func stallsPastTheRestartLimitEndTheRun() async throws {
        let notes = PostedNotes(center, [AVAudioEngineCapture.stalled, AVAudioEngineCapture.endedBySystem])
        let capture = capture()
        let stream = try capture.start()
        while notes.named(AVAudioEngineCapture.endedBySystem).isEmpty {
            try await step(capture, notes: notes)
        }
        let attempts = notes.named(AVAudioEngineCapture.stalled).map {
            $0.userInfo?[AVAudioEngineCapture.restartAttemptKey] as? UInt
        }
        #expect(attempts == [1, 2, 3], "two restarts, then the third stall ends the run")
        #expect(fake.starts == 3 && !fake.running && fake.tap == nil)
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == nil, "the stream finishes, so the consumer sees capture end")
    }

    @Test func aRestartThatFailsEndsTheRun() async throws {
        let notes = PostedNotes(center, [AVAudioEngineCapture.stalled, AVAudioEngineCapture.endedBySystem])
        let capture = capture()
        let stream = try capture.start()
        fake.failNextStart = true
        for _ in 0..<5 { try await step(capture, notes: notes) }
        #expect(notes.named(AVAudioEngineCapture.endedBySystem).count == 1)
        #expect(!fake.running && fake.tap == nil)
        var iterator = stream.makeAsyncIterator()
        #expect(await iterator.next() == nil)
    }

    @Test func withoutAPolicyNothingWatches() async throws {
        let capture = AVAudioEngineCapture(
            engine: AVAudioEngine(), notificationCenter: center, operations: fake.operations
        )
        let stream = try capture.start()
        for _ in 0..<20 { await Task.yield() }
        #expect(!sleeper.isWaiting)
        capture.stop()
        withExtendedLifetime(stream) {}
    }

    @Test func stoppingEndsTheWatchdog() async throws {
        let notes = PostedNotes(center, [AVAudioEngineCapture.stalled])
        let capture = capture()
        let stream = try capture.start()
        try await waitUntil { [sleeper] in sleeper.isWaiting }
        capture.stop()
        for _ in 0..<6 {
            sleeper.tick()
            for _ in 0..<20 { await Task.yield() }
        }
        #expect(notes.named(AVAudioEngineCapture.stalled).isEmpty)
        #expect(fake.starts == 1)
        withExtendedLifetime(stream) {}
    }
}

/// #443: a stall is recorded with the existing vocabulary, so hosts without a new capability accept it.
@MainActor
@Suite struct CaptureStallDiagnosticsTests {
    @Test func aStallIsRecordedAsACaptureErrorWithItsDurationAndAttempt() throws {
        let suite = "hail-capture-stall-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let log = DeviceDiagnostics(
            defaults: defaults, appInfo: [:], wallNow: { 1_000 }, clock: { ContinuousClock().now }
        )
        log.setEnabled(true)
        log.handle(AVAudioEngineCapture.stalled, [
            AVAudioEngineCapture.stalledMillisecondsKey: 5_000, AVAudioEngineCapture.restartAttemptKey: 2
        ])
        let events = try #require(log.nextBatch()).events
        let stall = try #require(events.last)
        #expect(stall.name == .captureError)
        #expect(stall.fields == [.code: .token("other"), .ms: .integer(5_000), .attempt: .integer(2)])
    }
}
