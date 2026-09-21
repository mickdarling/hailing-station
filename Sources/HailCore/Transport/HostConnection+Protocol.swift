import Foundation
import HailProtocol

extension HostConnection {
    func negotiate(
        on opened: any WebSocketTransport, token: UInt64
    ) async throws -> (version: Int, capabilities: [String]) {
        try await send(
            .hello(HelloInfo(
                versions: VersionNegotiation.supported,
                capabilities: ["connectivity_lab"],
                deviceName: deviceName
            )),
            generation: token
        )
        let data = try await opened.receive()
        guard isCurrent(token) else { throw CancellationError() }
        let frame: Frame
        do { frame = try FrameCoding.decode(data) } catch {
            throw HostConnectionFailure.malformed("host hello is malformed")
        }
        guard case .control(.hello(let info)) = frame.payload,
              let version = VersionNegotiation.choose(offered: info.versions),
              frame.version == version else {
            throw HostConnectionFailure.incompatibleVersion
        }
        return (version, info.capabilities)
    }

    func process(_ data: Data, generation token: UInt64) async throws {
        let frame: Frame
        do { frame = try FrameCoding.decode(data) } catch {
            throw HostConnectionFailure.malformed("host frame is malformed")
        }
        guard frame.version == snapshot.negotiatedVersion else {
            throw HostConnectionFailure.incompatibleVersion
        }
        switch frame.payload {
        case .control(let control):
            try await process(control)
        case .text(let text) where text.isFinal && text.reply != nil:
            try await publishReply(frame)
        case .audio(let audio) where audio.reply != nil:
            try await publishReply(frame)
        default:
            throw HostConnectionFailure.malformed("unexpected host frame")
        }
    }

    private func process(_ control: ControlPayload) async throws {
        switch control {
        case .pong(let nonce):
            guard let began = pendingPings.removeValue(forKey: nonce) else { return }
            let elapsed = began.duration(to: monotonicNow()).components
            snapshot.lastPingMilliseconds = (Double(elapsed.seconds) * 1_000)
                + (Double(elapsed.attoseconds) / 1_000_000_000_000_000)
            await observer(snapshot)
        case .targets(let targets):
            snapshot.targets = targets
            snapshot.receivedTargetList = true
            await observer(snapshot)
        case .error(let code, let message):
            throw HostConnectionFailure.remote("\(code.rawValue): \(message)")
        default:
            throw HostConnectionFailure.malformed("unexpected control frame")
        }
    }

    private func publishReply(_ frame: Frame) async throws {
        guard snapshot.capabilities.contains("receive_replies") else {
            throw HostConnectionFailure.unsupportedCapability("receive_replies")
        }
        await replyObserver(HostReplyEvent(endpointID: snapshot.id, frame: frame))
    }

    func sendPing(generation token: UInt64, requiresDeadline: Bool = false) async throws {
        let nonce = UUID().uuidString.lowercased()
        pendingPings[nonce] = monotonicNow()
        do { try await send(.ping(nonce: nonce), generation: token) } catch {
            pendingPings.removeValue(forKey: nonce)
            throw error
        }
        if requiresDeadline { schedulePongDeadline(nonce: nonce, generation: token) }
    }

    func schedulePongDeadline(nonce: String, generation token: UInt64) {
        Task { [weak self, pongTimeout, deadlineSleep] in
            do { try await deadlineSleep(pongTimeout) } catch { return }
            await self?.pongTimedOut(nonce: nonce, generation: token)
        }
    }

    func pongTimedOut(nonce: String, generation token: UInt64) async {
        guard isCurrent(token), wantsConnection,
              pendingPings.removeValue(forKey: nonce) != nil else { return }
        await replaceLoop()
    }

    func send(_ control: ControlPayload, generation token: UInt64) async throws {
        guard isCurrent(token), let socket else { throw CancellationError() }
        let frame = Frame(
            version: snapshot.negotiatedVersion ?? ProtocolVersion.current,
            timestamp: wallNow(), source: "terminal", payload: .control(control)
        )
        try await socket.send(FrameCoding.encode(frame))
    }

    func isCurrent(_ token: UInt64) -> Bool { token == generation }
    func publish(_ state: HostConnectionState, token: UInt64? = nil) async {
        guard token == nil || token == generation else { return }
        snapshot.state = state
        await observer(snapshot)
    }
}
