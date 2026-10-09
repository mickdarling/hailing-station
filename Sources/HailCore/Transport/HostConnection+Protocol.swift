import Foundation
public import HailProtocol

extension HostConnection {
    func negotiate(
        on opened: any WebSocketTransport, token: UInt64
    ) async throws -> (version: Int, capabilities: [String]) {
        try await send(
            .hello(HelloInfo(
                versions: VersionNegotiation.supported,
                capabilities: ["connectivity_lab", PlaybackStop.capability, AmbientTakeOver.capability],
                // The device's class only (#366), so a host can say "moved to iPad"; never its name.
                deviceName: deviceName, deviceKind: AmbientHandoff.localDeviceKind
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
        case .control(.stopPlayback), .control(.ambientMovedHere):
            // Like reply frames, needing no reply capability: a stop (#309) and a take-over notice (#366).
            await replyObserver(HostReplyEvent(endpointID: snapshot.id, frame: frame))
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
            let failure = HostConnectionFailure.remote("\(code.rawValue): \(message)")
            // The gate (#205) ends only the ambient stream and keeps the connection. Its error frames carry
            // no stream id, so they are recognised by the gate's "ambient" message prefix.
            guard message.hasPrefix("ambient"), let stream = ambientStream else { throw failure }
            ambientRefusal = (stream.id, failure)
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

    /// Sends one ambient segment (#203) in the existing `.audio` frame, addressed to the selected destination as
    /// the host gate requires. A stream is bound to the socket generation it started on; after a reconnect or
    /// a gate refusal for it, every further segment of that stream throws so the streamer releases the mic.
    public func sendAudio(_ audio: AudioPayload) async throws {
        try requireReady(capability: Self.streamAudioCapability)
        guard let targetID = desiredTargetID, selectionSettled, socket != nil else {
            throw HostConnectionFailure.notReady
        }
        guard audio.reply == nil, let stream = audio.streamID, audio.codec == .pcm16,
              audio.sampleRate == AmbientAudioFormat.sampleRate, audio.channels == AmbientAudioFormat.channels,
              !audio.bytes.isEmpty, audio.bytes.count.isMultiple(of: MemoryLayout<Int16>.size),
              audio.bytes.count <= AmbientAudioFormat.maxSegmentBytes else {
            throw HostConnectionFailure.malformed("ambient audio segment is malformed")
        }
        if let refusal = ambientRefusal, refusal.stream == stream { throw refusal.failure }
        let connection = snapshot.connectionGeneration
        try checkAmbientSequence(audio, stream: stream, connection: connection)
        if confirmedSelectionGeneration != connection {
            // Re-select and wait for the round trip so no segment can precede the restored selection.
            let token = generation
            let serial = selectionSerial
            try await send(.select(targetID: targetID), generation: token)
            try await confirmRoundTrip(generation: token)
            guard snapshot.connectionGeneration == connection, desiredTargetID == targetID,
                  selectionSerial == serial, selectionSettled else {
                throw HostConnectionFailure.notReady
            }
            confirmedSelectionGeneration = connection
        }
        ambientStream = (stream, connection)
        ambientLastSequence = audio.sequence
        let frame = Frame(
            version: snapshot.negotiatedVersion ?? ProtocolVersion.current,
            timestamp: wallNow(), target: targetID, source: deviceName, payload: .audio(audio)
        )
        guard let current = self.socket, snapshot.connectionGeneration == connection else {
            throw HostConnectionFailure.notReady
        }
        try await current.send(FrameCoding.encode(frame))
    }

    /// A stream stays on the connection it started on, starts at 0 and strictly increases (gaps allowed), as the
    /// gate (#205) requires; otherwise the host would end the stream.
    private func checkAmbientSequence(_ audio: AudioPayload, stream: UUID, connection: UUID) throws {
        if let current = ambientStream, current.id == stream, current.connection != connection {
            throw HostConnectionFailure.notReady
        }
        if ambientStream?.id != stream, audio.sequence != 0 {
            throw HostConnectionFailure.malformed("ambient stream must start at sequence 0")
        }
        if ambientStream?.id == stream, audio.sequence <= ambientLastSequence {
            throw HostConnectionFailure.malformed("ambient sequence must increase")
        }
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

    /// Confirms that the host processed every frame before this ping, including target selection.
    /// WebSocket message ordering makes the pong a lightweight selection acknowledgement without a
    /// protocol-version change that would break terminals already installed through TestFlight.
    func confirmRoundTrip(generation token: UInt64) async throws {
        let nonce = UUID().uuidString.lowercased()
        pendingPings[nonce] = monotonicNow()
        do {
            try await send(.ping(nonce: nonce), generation: token)
            schedulePongDeadline(nonce: nonce, generation: token)
            while pendingPings[nonce] != nil {
                guard isCurrent(token), wantsConnection else { throw HostConnectionFailure.notReady }
                try await Task.sleep(for: .milliseconds(10))
            }
            guard isCurrent(token), wantsConnection, snapshot.state == .ready else {
                throw HostConnectionFailure.notReady
            }
        } catch {
            pendingPings.removeValue(forKey: nonce)
            throw error
        }
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
