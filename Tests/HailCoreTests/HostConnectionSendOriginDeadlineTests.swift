import Foundation
import HailProtocol
import Testing
@testable import HailCore

@Suite struct HostConnectionSendOriginDeadlineTests {
    @Test func refusalOptInMustSurviveNegotiationDeadlineLoopReplacement() async throws {
        let host = try endpoint()
        let connector = ScriptedConnector()
        let first = ScriptedSocket()
        let second = ScriptedSocket()
        let deadline = DeadlineGate()
        let recorder = SendOriginRecorder()
        await connector.enqueue(.socket(first), for: host.url)
        await connector.enqueue(.socket(second), for: host.url)
        let connection = HostConnection(
            endpoint: host, connector: connector, deviceName: "Synthetic",
            deadlineSleep: { _ in throw CancellationError() },
            negotiationScheduler: { deadline.schedule($0, action: $1) },
            reportsAmbientRefusals: true, sleep: { _ in }, replyObserver: { await recorder.append($0) }
        )
        await connection.connect()
        try await waitUntil { try await first.sentFrames().count == 1 }
        // Real scheduling uses DispatchQueue; this detached callback likewise has no task-local opt-in.
        await Task.detached { deadline.fire() }.value
        try await awaitHello(connection, second, capabilities: ["select_target", "stream_audio", "receive_replies"])
        let selection = Task { try await connection.selectTarget(ambientTarget) }
        try await waitUntil { try await second.sentFrames().count >= 5 }
        let frames = try await second.sentFrames()
        guard case .control(.ping(let nonce)) = frames[4].payload else {
            throw SocketTestError.unavailable
        }
        try await second.push(.pong(nonce: nonce))
        try await selection.value
        let stream = UUID()
        try await connection.sendAudio(ambientSegment(stream: stream))
        try await second.push(.error(code: .notAllowed, message: "ambient moved to pad"))
        try await waitUntil { await connection.ambientRefusal?.stream == stream }
        #expect(await recorder.events.count == 1, "Timer-born loop lost immediate ambient refusal delivery")
        #expect(await recorder.streams == [stream])
        await connection.disconnect()
    }
}
