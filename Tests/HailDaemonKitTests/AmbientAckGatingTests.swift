#if os(macOS)
import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

/// Acknowledgement gating (rightyo#132): a request RightyO marks `acknowledge: false` on a session that advertised
/// `acknowledgement` reports a skip and plays nothing; a missing field, or an unadvertised session, still acknowledges.
@Suite(.timeLimit(.minutes(1))) struct AmbientAckGatingTests {
    static let gatedStart = #""type": "session", "phase": "started", "addressing": {"names": ["Jarvis"]}, "#
        + #""acknowledgement": {"version": 1, "min_confidence": 0.7}"#
    static let plainStart = #""type": "session", "phase": "started", "addressing": {"names": ["Jarvis"]}"#

    /// A relay that records what fired, after one `started` line.
    final class Recorder: Sendable {
        final class Log<Value: Sendable>: Sendable {
            private let entries = Mutex<[Value]>([])
            func append(_ value: Value) { entries.withLock { $0.append(value) } }
            var all: [Value] { entries.withLock { $0 } }
        }
        let acks: Log<AmbientAckRequest>, skips: Log<AmbientAckSkip>
        let relay: AmbientAckRelay

        init(started: String) throws {
            let (acks, skips) = (Log<AmbientAckRequest>(), Log<AmbientAckSkip>())
            (self.acks, self.skips) = (acks, skips)
            relay = AmbientAckRelay(onAcknowledge: { acks.append($0) }, onSkip: { skips.append($0) })
            relay.observe(try AmbientAckGatingTests.event(started), readAt: .now)
        }

        func admit(_ request: RightyoInputEvent) {
            relay.observe(request, readAt: .now)
            relay.fire()
        }
    }

    static func event(_ fields: String) throws -> RightyoInputEvent {
        try AmbientAcknowledgementTests.event(fields)
    }

    /// A request line; `extra` is spliced in as top-level fields (`acknowledge`, a decision).
    static func request(text: String = "and the next one", extra: String = "") throws -> RightyoInputEvent {
        try RightyoInputEvent.decode(Data("""
            {"schema_version": 1, "session_id": "s", "sequence": 2, "emitted_at_ms": 250, "type": "request",
             \(extra)
             "turn": {"session_id": "s", "utterance_id": "u", "revision": 1, "start_ms": 0, "end_ms": 10,
              "text": "\(text)", "finalized": true, "overlap": false, "recognizer_id": "r",
              "provenance": "live-microphone", "speaker_provenance": "none"}}
            """.utf8))
    }

    static let followUpDecision = #""decision": {"label": "attend", "recipient_kind": "unknown", "#
        + #""confidence": 0.22, "provider": "p", "model": "m", "follow_up": true},"#

    @Test func aGatedRequestIsNotAcknowledgedAndReportsItsSkip() throws {
        let recorder = try Recorder(started: Self.gatedStart)
        recorder.admit(try Self.request(extra: #""acknowledge": false, "# + Self.followUpDecision))
        recorder.relay.fire() // The skip disarmed the relay: nothing fires twice.
        #expect(recorder.acks.all.isEmpty)
        let skips = recorder.skips.all
        #expect(skips == [AmbientAckSkip(followUp: true, confidence: 0.22)])
        #expect(skips.first?.detail == "outcome=skipped reason=gated follow_up=true confidence=0.22")
    }

    @Test func aSkipDetailCarriesNoTranscriptText() throws {
        let recorder = try Recorder(started: Self.gatedStart)
        recorder.admit(try Self.request(text: "okay great secret words", extra: #""acknowledge": false,"#))
        let detail = try #require(recorder.skips.all.first).detail
        #expect(detail == "outcome=skipped reason=gated follow_up=false confidence=none")
        #expect(!detail.contains("secret"))
    }

    @Test func anAcknowledgedRequestIsArmedAndFires() throws {
        let recorder = try Recorder(started: Self.gatedStart)
        recorder.admit(try Self.request(text: "Jarvis, start", extra: #""acknowledge": true,"#))
        #expect(recorder.acks.all.map(\.persona) == ["jarvis"])
        #expect(recorder.skips.all.isEmpty)
    }

    @Test func aMissingFieldStillAcknowledges() throws {
        let recorder = try Recorder(started: Self.gatedStart)
        recorder.admit(try Self.request())
        #expect(recorder.acks.all.count == 1)
        #expect(recorder.skips.all.isEmpty)
    }

    /// Like `conversation` (rightyo#82), the field means something only on a session that advertised it.
    @Test func anUnadvertisedSessionIgnoresTheField() throws {
        let recorder = try Recorder(started: Self.plainStart)
        recorder.admit(try Self.request(extra: #""acknowledge": false,"#))
        #expect(recorder.acks.all.count == 1)
        #expect(recorder.skips.all.isEmpty)
    }

    /// The persona still sticks across a skipped turn, so the next acknowledged turn keeps the addressed voice.
    @Test func thePersonaSticksAcrossASkippedTurn() throws {
        let recorder = try Recorder(started: Self.gatedStart)
        recorder.admit(try Self.request(text: "Jarvis, start", extra: #""acknowledge": true,"#))
        recorder.admit(try Self.request(extra: #""acknowledge": false,"#))
        recorder.admit(try Self.request(extra: #""acknowledge": true,"#))
        #expect(recorder.acks.all.map(\.persona) == ["jarvis", "jarvis"])
        #expect(recorder.skips.all.count == 1)
    }

    /// A request that is never admitted (echo, withdrawn, duplicate) never fires, so it logs no skip either.
    @Test func anUnadmittedGatedRequestReportsNothing() throws {
        let recorder = try Recorder(started: Self.gatedStart)
        recorder.relay.observe(try Self.request(extra: #""acknowledge": false,"#), readAt: .now)
        recorder.relay.observe(try Self.event(#""type": "attention""#), readAt: .now)
        recorder.relay.fire()
        #expect(recorder.skips.all.isEmpty)
        #expect(recorder.acks.all.isEmpty)
    }
}
#endif
