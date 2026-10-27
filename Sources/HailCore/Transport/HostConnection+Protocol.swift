public import Foundation
public import HailProtocol

// The frame dispatch and its ambient and request-refusal cases stay together with negotiation.
// swiftlint:disable file_length

extension HostConnection {
    func negotiate(
        on opened: any WebSocketTransport, token: UInt64
    ) async throws -> (version: Int, capabilities: [String]) {
        let connectionGeneration = snapshot.connectionGeneration
        if let reporting = opened as? HostLossReportingSocket {
            await reporting.bind(connectionGeneration)
        }
        try await send(
            .hello(HelloInfo(
                versions: VersionNegotiation.supported,
                capabilities: ["connectivity_lab", PlaybackStop.capability, AmbientTakeOver.capability,
                               AmbientHeard.capability, AmbientOverheard.capability, ReplyMute.capability,
                               AmbientOverheard.namesCapability, OwnerVoice.capability, MediaMode.capability,
                               RequestRefusals.capability, HeardTurns.capability, ReplySegments.capability,
                               DuckMode.capability],
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
        case .control(.stopPlayback), .control(.setReplyMute), .control(.ambientMovedHere), .control(.ambientHeard),
             .control(.ambientOverheard), .control(.ownerVoice), .control(.mediaMode), .control(.healthReport),
             .control(.duckMode):
            // Like reply frames, needing no reply capability (#309, #404, #366, #318, rightyo#164, #612, #614, #735).
            await publishNotice(frame)
        case .control(.error(let code, _, _)) where code.isRequestRefusal: // #608: that request is over, not the link
            await publishNotice(frame)
        case .control(let control):
            try await process(control, frame: frame)
        case .text(let text) where text.isFinal && text.reply != nil:
            try await publishReply(frame)
        case .audio(let audio) where audio.reply != nil:
            try await publishReply(frame)
        default:
            throw HostConnectionFailure.malformed("unexpected host frame")
        }
    }

    private func publishNotice(_ frame: Frame, streamID: UUID? = nil) async {
        let origin = snapshot.connectionGeneration
        let event = HostReplyEvent(endpointID: snapshot.id, frame: frame)
        await HostNoticeOrigin.$streamID.withValue(streamID) {
            await HostNoticeOrigin.$generation.withValue(origin) { await replyObserver(event) }
        }
    }

    private func process(_ control: ControlPayload, frame: Frame) async throws {
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
        case .error(let code, let message, _):
            let failure = HostConnectionFailure.remote("\(code.rawValue): \(message)")
            // The gate (#205) ends only the ambient stream and keeps the connection. Its error frames carry
            // no stream id, so they are recognised by the gate's "ambient" message prefix.
            guard message.hasPrefix("ambient"), let stream = ambientStream else { throw failure }
            ambientRefusal = (stream.id, failure)
            // Opt-in for restore-aware callers only. Existing observers receive exactly their old events.
            if reportsAmbientRefusals { await publishNotice(frame, streamID: stream.id) }
        default:
            throw HostConnectionFailure.malformed("unexpected control frame")
        }
    }

    private func publishReply(_ frame: Frame) async throws {
        guard snapshot.capabilities.contains("receive_replies") else {
            throw HostConnectionFailure.unsupportedCapability("receive_replies")
        }
        await publishNotice(frame)
    }
}

extension HostConnection {
    /// A yield belongs to one ready, negotiated socket; never carry it across reconnects.
    func sendReplyYield(_ yield: ReplySegmentPause, connectionGeneration: UUID) async throws {
        try requireReady(capability: ReplySegments.capability)
        guard snapshot.connectionGeneration == connectionGeneration,
              yield.endpointID == snapshot.id else { throw HostConnectionFailure.notReady }
        try await send(.replyYield(reply: yield.replyID, segment: yield.segment), generation: generation)
    }

    /// Sends one ambient segment (#203) in the existing `.audio` frame, addressed to the selected destination as
    /// the host gate requires. A stream is bound to the socket generation it started on; after a reconnect or
    /// a gate refusal for it, every further segment of that stream throws so the streamer releases the mic.
    public func sendAudio(_ audio: AudioPayload, bindingGeneration: UUID? = nil) async throws {
        guard bindingGeneration == nil || bindingGeneration == snapshot.connectionGeneration,
              AmbientSendAdmission.isCurrent else { throw HostConnectionFailure.notReady }
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
        guard let current = self.socket, snapshot.connectionGeneration == connection,
              AmbientSendAdmission.isCurrent else {
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
        let frame = Frame(version: snapshot.negotiatedVersion ?? ProtocolVersion.current,
                          timestamp: wallNow(), source: "terminal", payload: .control(control))
        try await socket.send(FrameCoding.encode(frame))
    }

    func isCurrent(_ token: UInt64) -> Bool { token == generation }
    func publish(_ state: HostConnectionState, token: UInt64? = nil) async {
        guard token == nil || token == generation else { return }
        snapshot.state = state
        await observer(snapshot)
    }
}

/// Provenance survives the observer's executor hop. Refusal delivery is opted into by the connection's stored
/// `reportsAmbientRefusals` flag, so it survives every loop replacement, timer-born ones included.
enum HostNoticeOrigin {
    @TaskLocal static var generation: UUID?
    @TaskLocal static var streamID: UUID?
}

extension HostConnection {
    /// Told the socket's bound generation (and whether a send found it); only CancellationError and
    /// HostConnectionFailure are ignored. Transport-caused drops report before close or reconnect publication.
    /// Explicit disconnect or loop replacement can interrupt receive and report after `.disconnected`.
    /// Callers must veto explicit disconnects before calling disconnect(), as R1's store does.
    public typealias TransportLossObserver = @Sendable (_ generation: UUID, _ sending: Bool) async -> Void
}

/// Installed only for an explicit loss observer. The default connector and transport stay unchanged.
/// Only CancellationError and HostConnectionFailure are ignored; transport-caused drops report before close.
/// Explicit disconnect or loop replacement can report interrupted receive after `.disconnected` with the bound
/// generation. Callers must veto explicit disconnects before calling disconnect(), as R1's store does.
struct HostLossReportingConnector: WebSocketConnecting {
    let base: any WebSocketConnecting
    let observer: HostConnection.TransportLossObserver
    static func wrapping(_ connector: any WebSocketConnecting,
                         observer: HostConnection.TransportLossObserver?) -> any WebSocketConnecting {
        guard let observer else { return connector }
        return HostLossReportingConnector(base: connector, observer: observer)
    }
    func open(url: URL, subprotocol: String) async throws -> any WebSocketTransport {
        let socket = try await base.open(url: url, subprotocol: subprotocol)
        return HostLossReportingSocket(base: socket, observer: observer)
    }
}

/// Reports the socket's bound generation, ignoring only CancellationError and HostConnectionFailure.
/// Transport-caused drops report before close/publication; explicit disconnect or loop replacement can report
/// interrupted receive after `.disconnected`. Callers must veto explicit disconnects before calling disconnect(),
/// as R1's store does.
actor HostLossReportingSocket: WebSocketTransport {
    let base: any WebSocketTransport
    let observer: HostConnection.TransportLossObserver
    private var generation: UUID?
    init(base: any WebSocketTransport, observer: @escaping HostConnection.TransportLossObserver) {
        self.base = base
        self.observer = observer
    }
    func bind(_ generation: UUID) { self.generation = generation }
    func send(_ data: Data) async throws {
        do {
            try await base.send(data)
        } catch {
            await report(error, sending: true)
            throw error
        }
    }
    func receive() async throws -> Data {
        do {
            return try await base.receive()
        } catch {
            await report(error, sending: false)
            throw error
        }
    }
    private func report(_ error: any Error, sending: Bool) async {
        guard !(error is CancellationError), !(error is HostConnectionFailure), let generation else { return }
        await observer(generation, sending)
    }
    func close() async { await base.close() }
}
