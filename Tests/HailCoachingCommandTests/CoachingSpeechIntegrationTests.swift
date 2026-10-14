import Foundation
import HailCore
import HailProtocol
import Testing
@testable import haild
@testable import HailCoaching

@MainActor private final class ComposedSpeechSource: CoachingSpeechSource {
    var cleanups: [Bool] = []
    func consume(_ receive: (Data) throws -> Void) async throws { try receive(Data([17, 0])) }
    func finish() async throws {}
    func cancel() {}
    func cleanup(cancel: Bool) async throws { cleanups.append(cancel) }
}

@MainActor private final class ComposedSpeechTransport: ForegroundCoachingTransport {
    let hooks: ForegroundCoaching.ChildHooks
    var closed = false, stopped = false
    init(_ hooks: ForegroundCoaching.ChildHooks) { self.hooks = hooks }
    func send(_ control: ForegroundCoachingControl) -> Bool { !closed }
    func write(_ buffer: AudioCaptureBuffer) -> Bool { !closed }
    func close() { closed = true }
    func stop() async { closed = true; stopped = true }
}

/// The public foreground owner, real private consumer and authored player, not a permissive emit callback.
@Suite(.serialized, .timeLimit(.minutes(1))) @MainActor struct CoachingSpeechIntegrationTests {
    @Test func admittedASCIIAndEscapedPrintableUnicodeReachPrivatePlayback() async throws {
        for text in ["authored suggestion", "Clarify café priorities."] {
            let source = ComposedSpeechSource()
            let speech = CoachingSpeechRenderer { _ in source }
            let capture = ExecutableCoachingCapture(), player = ExecutablePrivatePlayer()
            var audio: ExecutablePrivateAudio?, transport: ComposedSpeechTransport?
            // This authored composition checks text/PCM delivery and joined cleanup, not elapsed-time expiry.
            let instant = ContinuousClock.now
            let clock = CoachingClock(now: { instant }, schedule: { _, _ in {} })
            let owner = try ForegroundCoaching(listenerID: "coach", transport: { hooks in
                let child = ComposedSpeechTransport(hooks); transport = child; return child
            }, audio: { hooks in
                let privateAudio = try ExecutablePrivateAudio(
                    capture: capture, player: player, hooks: hooks, clock: clock)
                audio = privateAudio; return privateAudio
            }, speech: speech, clock: clock)
            try owner.enable(participantAwareness: true)
            let lease = try #require(audio?.session.qualification)
            let raw = try JSONSerialization.data(withJSONObject: ["schema_version": 1, "type": "coaching_advice",
                "session_id": lease.sessionID.uuidString.lowercased(),
                "generation_id": lease.generation.uuidString.lowercased(),
                "destination_id": lease.destinationID.uuidString.lowercased(),
                "qualification_id": lease.qualificationID.uuidString.lowercased(),
                "request_id": UUID().uuidString.lowercased(), "listener_id": "coach", "valid_for_ms": 1_000,
                "delivery": "owner_private", "text": text,
                "decision": ["label": "speak_now", "confidence": 1, "provider": "authored", "model": "fake"]])
            let rawText = try #require(String(data: raw, encoding: .utf8))
            let encoded = Data(rawText.replacingOccurrences(of: "é", with: "\\u00e9").utf8)
            #expect(encoded.allSatisfy { $0 < 128 })
            _ = try CoachingWireAdvice.decode(encoded)
            transport?.hooks.advice(encoded)
            let delivered = ContinuousClock.now.advanced(by: .seconds(5))
            while player.played == 0 || source.cleanups.isEmpty,
                  owner.status != .off, ContinuousClock.now < delivered {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(player.played == 1 && player.nonzeroBytes == 1 && owner.status == .active)
            #expect(source.cleanups == [false])
            try await retire(owner)
            #expect(owner.status == .off && transport?.stopped == true)
        }
    }

    private func retire(_ owner: ForegroundCoaching) async throws {
        owner.off()
        let retired = ContinuousClock.now.advanced(by: .seconds(5))
        while owner.status != .off, ContinuousClock.now < retired {
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}
