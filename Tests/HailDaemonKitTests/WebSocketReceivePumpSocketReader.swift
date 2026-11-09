import Foundation
import HailProtocol
import Testing

/// One retained application receive, submitted synchronously before the transport ping.
final class PumpSocketReader: Sendable {
    let socket: URLSessionWebSocketTask
    private let received = SelectionPreflightSignal<URLSessionWebSocketTask.Message>()

    init(_ socket: URLSessionWebSocketTask) {
        self.socket = socket
        let received = received
        socket.receive { received.finish($0) }
    }

    func cancel() {
        socket.cancel(with: .goingAway, reason: nil)
        received.finish(.failure(CancellationError()))
    }

    func frame(step: String) async throws -> Frame {
        let message: URLSessionWebSocketTask.Message
        do { message = try await received.wait(step, timeout: .seconds(15)) } catch {
            cancel()
            throw error
        }
        switch message {
        case .data(let data): return try FrameCoding.decode(data)
        case .string(let string): return try FrameCoding.decode(Data(string.utf8))
        @unknown default: throw TestSupportError.expectedOneControl
        }
    }

    func barrier(step: String) async throws {
        let nonce = UUID().uuidString
        try await recipientSocketSend(sessionFrame(payload: .control(.ping(nonce: nonce))), on: socket)
        let received = try await frame(step: step).payload
        try #require(received == .control(.pong(nonce: nonce)), "Unexpected payload at \(step): \(received)")
    }
}

// macOS 15 URLSession fires pong callbacks only while a receive is pending. Keep that receive's result
// for the caller's next application assertion; cancellation closes the socket to bound cleanup.
func pumpSocketPing(
    _ socket: URLSessionWebSocketTask
) async throws -> (reader: PumpSocketReader, pongAt: ContinuousClock.Instant) {
    let reader = PumpSocketReader(socket)
    let pong = SelectionPreflightSignal<ContinuousClock.Instant>()
    socket.sendPing { error in
        if let error { pong.finish(.failure(error)) } else { pong.finish(.success(ContinuousClock.now)) }
    }
    do { return (reader, try await pong.wait("transport pong")) } catch {
        reader.cancel()
        throw error
    }
}
