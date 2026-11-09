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

    static func make(backlogBytes: Int = 524_288) async throws -> Self {
        let fake = try FakeRightyo("""
        /usr/bin/sed -n '1p' events.jsonl | /usr/bin/sed "s/formed-demo/$7/g"
        /bin/cat > "$7.raw"
        /usr/bin/sed -n '$p' events.jsonl | /usr/bin/sed "s/formed-demo/$7/g"
        """)
        do {
            try fake.install(fixture: "enrolled-formed-request.jsonl")
            let logs = AmbientGapFillLogs()
            let env = try await ambientRig(fake, timing: .init(
                eofGrace: 20, termGrace: 20, backlogBytes: backlogBytes, backlogAge: 60
            ), onEvent: { event in logs.events.withLock { $0.append(event) } })
            return Self(fake: fake, env: env, logs: logs)
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

    func heard(_ session: String) throws -> Data {
        try Data(contentsOf: fake.directory.appendingPathComponent("\(session).raw"))
    }

    var fills: [WebSocketListenerEvent] { logs.events.withLock { $0.filter { $0.event == "ambient_gap_filled" } } }

    func finish() async {
        await env.listener.stop(reason: "synthetic gap test complete")
        fake.cleanUp()
    }
}
#endif
