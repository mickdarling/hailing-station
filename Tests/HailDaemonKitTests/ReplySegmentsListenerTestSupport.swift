import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

final class ReplySegmentsEvents: Sendable {
    private let events = Mutex<[WebSocketListenerEvent]>([])
    func record(_ event: WebSocketListenerEvent) { events.withLock { $0.append(event) } }
    var control: [WebSocketListenerEvent] {
        events.withLock { $0.filter { ["reply_yield", "reply_backstop"].contains($0.event) } }
    }
}

struct ReplySegmentsDevice {
    let urlSession: URLSession
    let socket: URLSessionWebSocketTask
    let peer: WebSocketPeer
    let session: HostSession
    let hello: HelloInfo

    func yield(_ reply: UUID, segment: Int = 1) async throws {
        try await recipientSocketSend(sessionFrame(payload: .control(.replyYield(reply: reply, segment: segment))),
                                      on: socket)
    }

    func close() {
        socket.cancel(with: .normalClosure, reason: nil)
        urlSession.invalidateAndCancel()
    }
}

struct ReplySegmentsRig {
    let recipient: RecipientTestRig
    let listener: WebSocketListener
    let events: ReplySegmentsEvents
    let first: ReplySegmentsDevice
    let second: ReplySegmentsDevice

    static func withDevices(
        firstCapable: Bool = true, secondCapable: Bool = true,
        _ body: (Self) async throws -> Void
    ) async throws {
        let recipient = try await RecipientTestRig.make()
        let events = ReplySegmentsEvents()
        let listener = try WebSocketListener(
            bindAddress: "127.0.0.1", port: 0, host: recipient.host,
            authorizer: PersonalTerminalAuthorizer(), hostName: "mac-test", singleTerminalReplyFallback: true,
            log: events.record
        )
        let port = try await listener.start()
        do {
            let first = try await device(listener, port: port, capable: firstCapable)
            defer { first.close() }
            let second = try await device(listener, port: port, capable: secondCapable)
            defer { second.close() }
            try await body(Self(recipient: recipient, listener: listener, events: events, first: first, second: second))
        } catch {
            await listener.stop(reason: "synthetic test failed")
            throw error
        }
        await listener.stop(reason: "synthetic test complete")
    }

    private static func device(
        _ listener: WebSocketListener, port: UInt16, capable: Bool
    ) async throws -> ReplySegmentsDevice {
        let previous = await listener.segmentTestPeerIDs()
        let (urlSession, socket) = try recipientSocket(port: port)
        do {
            let caps = [PlaybackStop.capability] + (capable ? [ReplySegments.capability] : [])
            try await recipientSocketSend(helloFrame(capabilities: caps), on: socket)
            guard case .control(.hello(let hello)) = try await recipientSocketReceive(on: socket).payload else {
                throw TestSupportError.expectedOneControl
            }
            try await recipientSocketSend(
                sessionFrame(payload: .control(.select(targetID: RecipientTestRig.target))), on: socket
            )
            try await recipientSocketBarrier(on: socket)
            let peer = try #require(await listener.segmentTestNewPeer(excluding: previous))
            return ReplySegmentsDevice(urlSession: urlSession, socket: socket, peer: peer,
                                       session: await peer.session, hello: hello)
        } catch {
            socket.cancel(with: .normalClosure, reason: nil)
            urlSession.invalidateAndCancel()
            throw error
        }
    }

    func startReply(on device: ReplySegmentsDevice, segmented: Bool = true) async throws -> ReplyDescriptor {
        let reply = recipientDescriptor(try await recipient.submit(on: device.session), audio: true)
        let first = segmentAudio(reply, sequence: 0, segmentEnd: segmented)
        try #require(await listener.publish(first) == 1)
        let received = try await recipientSocketReceive(on: device.socket)
        let capable = await device.session.peerCapabilities.contains(ReplySegments.capability)
        #expect(received == deviceFrame(first, capable: capable))
        return reply
    }
}

func segmentAudio(_ reply: ReplyDescriptor, sequence: Int, segmentEnd: Bool = true, final: Bool = false) -> Frame {
    var frame = recipientAudio(reply, sequence: sequence, final: final)
    if case .audio(var audio) = frame.payload {
        audio.isSegmentEnd = segmentEnd
        frame.payload = .audio(audio)
    }
    return frame
}

func deviceFrame(_ frame: Frame, capable: Bool) -> Frame {
    guard !capable, case .audio(var audio) = frame.payload else { return frame }
    audio.isSegmentEnd = false
    var frame = frame
    frame.payload = .audio(audio)
    return frame
}

extension WebSocketListener {
    fileprivate func segmentTestPeerIDs() -> Set<UUID> { Set(peers.keys) }
    fileprivate func segmentTestNewPeer(excluding previous: Set<UUID>) -> WebSocketPeer? {
        peers.first { !previous.contains($0.key) }?.value
    }
    func segmentTestStopped(_ id: UUID) -> Bool { stoppedReplyIDs.contains(id) }
}

/// Actual wire bytes, so legacy equality is checked before any decode/re-encode normalization.
func segmentSocketBytes(on socket: URLSessionWebSocketTask) async throws -> Data {
    let deadline = Task {
        try await Task.sleep(for: .seconds(15))
        socket.cancel(with: .goingAway, reason: nil)
    }
    defer { deadline.cancel() }
    switch try await socket.receive() {
    case .data(let bytes): return bytes
    case .string(let text): return Data(text.utf8)
    @unknown default: throw TestSupportError.expectedOneControl
    }
}
