import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

func recipientSocket(port: UInt16) throws -> (URLSession, URLSessionWebSocketTask) {
    let session = URLSession(configuration: .ephemeral)
    let url = try #require(URL(string: "ws://127.0.0.1:\(port)"))
    let socket = session.webSocketTask(with: url, protocols: [WebSocketListener.subprotocolName])
    socket.resume()
    return (session, socket)
}

func recipientSocketSend(
    _ frame: Frame, on socket: URLSessionWebSocketTask, within: Duration = .seconds(15)
) async throws {
    try await recipientSocketOperation(on: socket, step: "recipient send", within: within) {
        try await socket.send(.data(FrameCoding.encode(frame)))
    }
}

/// The next frame on `socket`. `URLSessionWebSocketTask.receive()` ignores task cancellation, so a frame that never
/// came held the test, and its whole lane, until the 300 s stall stop (#704). After `within` the socket is cancelled,
/// which ends the receive, and a recorded issue names `step`. Any other error (a server close a test expects) is
/// thrown as before, with no issue.
func recipientSocketReceive(
    on socket: URLSessionWebSocketTask, step: String = "recipient receive", within: Duration = .seconds(15)
) async throws -> Frame {
    let message = try await recipientSocketOperation(on: socket, step: step, within: within) {
        try await socket.receive()
    }
    switch message {
    case .data(let data): return try FrameCoding.decode(data)
    case .string(let string): return try FrameCoding.decode(Data(string.utf8))
    @unknown default: throw TestSupportError.expectedOneControl
    }
}

private enum RecipientSocketWait { case waiting, done, expired }

/// #896: sends can stall too. Cancel the socket, since cancelling only the Swift task cannot end Foundation I/O.
private func recipientSocketOperation<Value: Sendable>(
    on socket: URLSessionWebSocketTask, step: String, within: Duration,
    _ operation: @Sendable () async throws -> Value
) async throws -> Value {
    let wait = Mutex(RecipientSocketWait.waiting)
    let timer = Task {
        try await Task.sleep(for: within)
        let expired = wait.withLock { state in
            if state == .waiting { state = .expired }
            return state == .expired
        }
        if expired { socket.cancel(with: .goingAway, reason: nil) }
    }
    defer {
        timer.cancel()
        wait.withLock { if $0 == .waiting { $0 = .done } }
    }
    do {
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await operation()
        } onCancel: {
            socket.cancel(with: .goingAway, reason: nil)
        }
    } catch {
        let expired = wait.withLock { state in
            defer { if state == .waiting { state = .done } }
            return state == .expired
        }
        if expired { Issue.record("#896: socket operation exceeded \(within) at: \(step)") }
        throw error
    }
}

/// The pong follows prior host publications on this peer's serial send queue. A stray reply is a failure,
/// not a timeout-based inference that nothing arrived.
func recipientSocketBarrier(on socket: URLSessionWebSocketTask, step: String = "recipient barrier") async throws {
    let nonce = UUID().uuidString
    try await recipientSocketSend(sessionFrame(payload: .control(.ping(nonce: nonce))), on: socket)
    let received = try await recipientSocketReceive(on: socket, step: step).payload
    try #require(received == .control(.pong(nonce: nonce)), "Unexpected payload at \(step): \(received)")
}
