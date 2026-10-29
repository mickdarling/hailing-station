import AVFAudio
import Foundation
import Testing
@testable import HailCore

@MainActor
@Suite(.serialized) struct AmbientCallEngineGuardTests {
    @Test func stallHealKeepsThePostRestartRunningGuard() async throws {
        let center = NotificationCenter()
        let engine = AVAudioEngine()
        let fake = CountingEngineOperations()
        let clock = SteppedSleeper()
        let restarted = AudioEngineCaptureStartupSignalTests.EndedFlag()
        let notes = PostedNotes(center, [AVAudioEngineCapture.endedBySystem])
        let sent = SentAudio()
        var operations = fake.operations
        let start = operations.start
        operations.start = { engine in
            if fake.starts == 1 {
                center.post(name: .AVAudioEngineConfigurationChange, object: engine)
                restarted.set()
            }
            try start(engine)
        }
        let capture = AVAudioEngineCapture(
            engine: engine, notificationCenter: center, operations: operations,
            stallPolicy: .init(limit: .seconds(1), check: .seconds(1), maxRestarts: 1),
            now: { clock.clock.now() }, sleep: { try await clock.sleep($0) }
        )
        let streamer = AmbientAudioStreamer(capture: capture, send: { await sent.send($0) })
        try streamer.start()
        for _ in 0..<2 {
            try await callEventually { clock.isWaiting }
            clock.tick()
        }
        try await callEventually { restarted.value && clock.isWaiting }
        for _ in 0..<6 { fake.feed(try sineBuffer()) }
        await streamer.stop()
        #expect(notes.named(AVAudioEngineCapture.endedBySystem).isEmpty)
        #expect(!(await sent.payloads).isEmpty)
        capture.stop()
        clock.tick()
    }
}
