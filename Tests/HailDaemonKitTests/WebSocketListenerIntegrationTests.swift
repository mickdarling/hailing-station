import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

@Suite struct WebSocketListenerIntegrationTests {
    @Test func wildcardAddressesAreRefusedBeforeListening() async throws {
        let (host, _) = try await sessionHost()
        for address in [
            "", "*", "0", "0.0", "0.0.0", "0.0.0.0", "::", "::0", "0::", "[::]",
            "0:0:0:0:0:0:0:0", "::ffff:0.0.0.0", "::ffff:127.0.0.1", "localhost"
        ] {
            #expect(throws: WebSocketListenerError.invalidBindAddress(address)) {
                try WebSocketListener(bindAddress: address, port: 0, host: host)
            }
        }
    }

    @Test func fixedPortBindsThroughTheRequiredLocalEndpoint() async throws {
        let (host, _) = try await sessionHost()
        let reservation = try WebSocketListener(bindAddress: "127.0.0.1", port: 0, host: host)
        let freePort = try await reservation.start()
        await reservation.stop(reason: "port selected")

        // Network.framework reports cancellation asynchronously. Retry only the transient address-in-use
        // result while the reservation drains; any other fixed-port failure remains an immediate failure.
        for attempt in 0..<20 {
            let listener = try WebSocketListener(bindAddress: "127.0.0.1", port: freePort, host: host)
            do {
                #expect(try await listener.start() == freePort)
                await listener.stop(reason: "test complete")
                return
            } catch WebSocketListenerError.failed(let detail)
                where detail.localizedCaseInsensitiveContains("address already in use") && attempt < 19 {
                await listener.stop(reason: "retrying released port")
                try await Task.sleep(for: .milliseconds(25))
            }
        }
        Issue.record("reserved loopback port was not released")
    }

    @Test func localClientNegotiatesPingsAndListsFilteredTargets() async throws {
        var policy = Policy()
        try policy.allow("tmux:allowed", binding: "a", tier: .open)
        let (host, _) = try await sessionHost(
            targets: [AdapterTarget(name: "allowed", binding: "a"), AdapterTarget(name: "denied", binding: "b")],
            policy: policy
        )
        let listener = try WebSocketListener(bindAddress: "127.0.0.1", port: 0, host: host)
        let port = try await listener.start()

        do {
            let (urlSession, socket) = try client(port: port)
            defer {
                socket.cancel(with: .normalClosure, reason: nil)
                urlSession.invalidateAndCancel()
            }
            try await send(helloFrame(), on: socket)
            let hello = try await receive(on: socket)
            guard case .control(.hello(let info)) = hello.payload else {
                Issue.record("expected host hello")
                await listener.stop(reason: "test complete")
                return
            }
            #expect(info.versions == [1])

            try await send(sessionFrame(payload: .control(.ping(nonce: "live"))), on: socket)
            #expect(try await receiveControl(on: socket) == .pong(nonce: "live"))

            try await send(sessionFrame(payload: .control(.listTargets)), on: socket)
            guard case .targets(let targets) = try await receiveControl(on: socket) else {
                Issue.record("expected targets")
                await listener.stop(reason: "test complete")
                return
            }
            #expect(targets.map(\.id) == ["tmux:allowed"])
        } catch {
            await listener.stop(reason: "test failed")
            throw error
        }
        await listener.stop(reason: "test complete")
    }

    @Test func twoProbeClientsKeepIndependentNegotiatedState() async throws {
        let (host, _) = try await sessionHost()
        let listener = try WebSocketListener(bindAddress: "127.0.0.1", port: 0, host: host)
        let port = try await listener.start()

        do {
            let (firstSession, first) = try client(port: port)
            let (secondSession, second) = try client(port: port)
            defer {
                first.cancel(with: .normalClosure, reason: nil)
                second.cancel(with: .normalClosure, reason: nil)
                firstSession.invalidateAndCancel()
                secondSession.invalidateAndCancel()
            }
            try await send(helloFrame(), on: first)
            try await send(helloFrame(), on: second)
            _ = try await receive(on: first)
            _ = try await receive(on: second)

            try await send(sessionFrame(payload: .control(.ping(nonce: "first"))), on: first)
            try await send(sessionFrame(payload: .control(.ping(nonce: "second"))), on: second)
            #expect(try await receiveControl(on: first) == .pong(nonce: "first"))
            #expect(try await receiveControl(on: second) == .pong(nonce: "second"))
        } catch {
            await listener.stop(reason: "test failed")
            throw error
        }
        await listener.stop(reason: "test complete")
    }

    @Test func silentClientsHaveADeadlineAndAdmissionIsBounded() async throws {
        let (host, _) = try await sessionHost()
        let events = ListenerEventLog()
        let listener = try WebSocketListener(
            bindAddress: "127.0.0.1", port: 0, host: host,
            maxConnections: 1, helloTimeout: .milliseconds(500)
        ) { event in
            Task { await events.record(event) }
        }
        let port = try await listener.start()
        let (firstSession, first) = try client(port: port)
        defer {
            first.cancel(with: .normalClosure, reason: nil)
            firstSession.invalidateAndCancel()
        }
        try await ping(first)

        let (secondSession, second) = try client(port: port)
        defer {
            second.cancel(with: .normalClosure, reason: nil)
            secondSession.invalidateAndCancel()
        }
        let secondPing = Task { try? await ping(second) }

        let rejected = await events.waitFor(event: "session_rejected", detail: "connection limit reached")
        let rejectionEvents = await events.snapshot()
        #expect(rejected, "observed events: \(rejectionEvents)")
        secondPing.cancel()
        let timedOut = await events.waitFor(event: "session_disconnected", detail: "hello timeout")
        let timeoutEvents = await events.snapshot()
        #expect(timedOut, "observed events: \(timeoutEvents)")
        await listener.stop(reason: "test complete")
    }

    private func send(_ frame: Frame, on socket: URLSessionWebSocketTask) async throws {
        let data = try FrameCoding.encode(frame)
        let text = try #require(String(bytes: data, encoding: .utf8))
        try await socket.send(.string(text))
    }

    private func receive(on socket: URLSessionWebSocketTask) async throws -> Frame {
        switch try await socket.receive() {
        case .data(let data): return try FrameCoding.decode(data)
        case .string(let string): return try FrameCoding.decode(Data(string.utf8))
        @unknown default: throw TestSupportError.expectedOneControl
        }
    }

    private func receiveControl(on socket: URLSessionWebSocketTask) async throws -> ControlPayload {
        let frame = try await receive(on: socket)
        guard case .control(let control) = frame.payload else { throw TestSupportError.expectedOneControl }
        return control
    }
}

private func client(port: UInt16) throws -> (URLSession, URLSessionWebSocketTask) {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.timeoutIntervalForRequest = 5
    let session = URLSession(configuration: configuration)
    let url = try #require(URL(string: "ws://127.0.0.1:\(port)"))
    let socket = session.webSocketTask(with: url, protocols: [WebSocketListener.subprotocolName])
    socket.resume()
    return (session, socket)
}

private func ping(_ socket: URLSessionWebSocketTask) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
        socket.sendPing { error in
            if let error { continuation.resume(throwing: error) } else { continuation.resume() }
        }
    }
}

private actor ListenerEventLog {
    private var events: [WebSocketListenerEvent] = []

    func record(_ event: WebSocketListenerEvent) { events.append(event) }
    func snapshot() -> [WebSocketListenerEvent] { events }

    func waitFor(event: String, detail: String) async -> Bool {
        for _ in 0..<100 {
            if events.contains(where: { $0.event == event && $0.detail == detail }) { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return false
    }
}
