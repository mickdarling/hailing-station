import Foundation
import HailCore
import HailProtocol
import Testing
@testable import haild

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
            let owner = try ForegroundCoaching(listenerID: "coach", transport: { hooks in
                let child = ComposedSpeechTransport(hooks); transport = child; return child
            }, audio: { hooks in
                let privateAudio = try ExecutablePrivateAudio(capture: capture, player: player, hooks: hooks)
                audio = privateAudio; return privateAudio
            }, speech: speech)
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
            for _ in 0..<100 where player.played == 0 && owner.status != .off {
                try await Task.sleep(for: .milliseconds(10))
            }
            #expect(player.played == 1 && player.nonzeroBytes == 1 && owner.status == .active)
            #expect(source.cleanups == [false])
            owner.off()
            for _ in 0..<100 where owner.status != .off { try await Task.sleep(for: .milliseconds(10)) }
            #expect(owner.status == .off && transport?.stopped == true)
        }
    }
}
