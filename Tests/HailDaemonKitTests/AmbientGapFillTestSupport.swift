#if os(macOS)
import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

final class AmbientGapFillLogs: Sendable {
    let events = Mutex<[WebSocketListenerEvent]>([])
}

/// Synthetic RightyO stdin capture; actor returns and EOF/reaped tasks acknowledge processing, never elapsed time.
struct AmbientGapFillRig {
    let fake: FakeRightyo
    let env: AmbientWiringRig
    let connection = UUID()
    let logs: AmbientGapFillLogs
    let clock: AmbientGapTestClock

    static func make(backlogBytes: Int = 524_288, holdStarted: Bool = false) async throws -> Self {
        let fake = try FakeRightyo(holdStarted ? """
        /bin/cat > "$7.raw"
        /usr/bin/sed -n -e '1p' -e '$p' events.jsonl | /usr/bin/sed "s/formed-demo/$7/g"
        """ : """
        /usr/bin/sed -n '1p' events.jsonl | /usr/bin/sed "s/formed-demo/$7/g"
        /bin/cat > "$7.raw"
        /usr/bin/sed -n '$p' events.jsonl | /usr/bin/sed "s/formed-demo/$7/g"
        """)
        do {
            try fake.install(fixture: "enrolled-formed-request.jsonl")
            let logs = AmbientGapFillLogs()
            let clock = AmbientGapTestClock()
            let env = try await ambientRig(fake, timing: .init(
                eofGrace: 20, termGrace: 20, backlogBytes: backlogBytes, backlogAge: 60
            ), replyControl: true, onEvent: { event in
                logs.events.withLock { $0.append(event) }
            }, gapClock: { clock.now }, admissionBinding: "reply-binding")
            return Self(fake: fake, env: env, logs: logs, clock: clock)
        } catch { fake.cleanUp(); throw error }
    }

    func send(_ stream: UUID, _ sequence: Int, final: Bool = false) async throws {
        let refusal = await env.gate.admit(Self.segment(stream, sequence, final: final),
                                          connection: connection, target: RecipientTestRig.target)
        try #require(refusal == nil)
    }

    static func segment(_ stream: UUID, _ sequence: Int, final: Bool = false) -> AudioPayload {
        var audio = ambientSegment(stream: stream, sequence: sequence, isFinal: final)
        audio.bytes = chunk(sequence)
        return audio
    }

    static func chunk(_ sequence: Int) -> Data { Data(repeating: UInt8(sequence % 251 + 1), count: 3_200) }
    static func silence(_ segments: Int) -> Data { Data(repeating: 0, count: min(segments, 30) * 3_200) }
    /// Concatenates expected child bytes in one typed step; chained `+` exceeds host Swift 6.2.4's type-check budget.
    static func joined(_ parts: Data...) -> Data { parts.reduce(into: Data()) { $0.append($1) } }

    func heard(_ session: String) throws -> Data {
        try Data(contentsOf: fake.directory.appendingPathComponent("\(session).raw"))
    }

    var fills: [WebSocketListenerEvent] { logs.events.withLock { $0.filter { $0.event == "ambient_gap_filled" } } }

    func finish() async {
        await env.listener.stop(reason: "synthetic gap test complete")
        fake.cleanUp()
    }
}
/// An injected monotonic instant; advancing it never waits for the wall clock.
final class AmbientGapTestClock: Sendable {
    private let instant = Mutex(ContinuousClock.now)
    var now: ContinuousClock.Instant { instant.withLock { $0 } }
    func advance(_ duration: Duration) { instant.withLock { $0 += duration } }
}
#endif
