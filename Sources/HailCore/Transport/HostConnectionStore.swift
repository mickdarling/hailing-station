// swiftlint:disable file_length
#if os(iOS)
import AVFAudio
#endif
public import Foundation
public import HailProtocol
public import Observation
import Network
/// Main-actor model for the UI. Every endpoint owns a separate actor and a separate stale-callback token.
@MainActor
@Observable
public final class HostConnectionStore {
    public static let replyFrameLimit = 256
    public private(set) var snapshots: [HostEndpoint.Identifier: HostConnectionSnapshot] = [:]
    public private(set) var order: [HostEndpoint.Identifier] = []
    /// A bounded ingress history for the playback coordinator. Audio is not associated by arrival order;
    /// consumers group these frames by the reply and stream identities carried in every frame.
    public private(set) var replyFrames: [HostReplyEvent] = []
    /// Called for every reply frame as it arrives, so replies reach the player while the app is in the background,
    /// when SwiftUI view updates such as `onChange` may not run (#282).
    @ObservationIgnored public var onReplyFrame: (@MainActor (HostReplyEvent) -> Void)?
    /// Called once for each request the host refused (any `ErrorCode.isRequestRefusal`), with its message, so the app
    /// can announce it once; the chat already shows it (#608, #636).
    @ObservationIgnored public var onRequestRefusal: (@MainActor (String) -> Void)?
    /// Each successful local onset yield gets a distinct id, including repeated yields after Replay.
    /// Content-free, memory-only event for observers such as the P5 notice; transport success is separate.
    public private(set) var segmentYieldEvent: ReplySegmentYieldEvent?
    @ObservationIgnored var segmentWiring: ReplySegmentDeviceWiring?
    /// The station chat (#288): requests as they are sent and replies as they arrive, in the background too.
    public let conversation = ConversationLog()
    /// True while ambient listening is streaming; leaving the foreground then keeps the destination authorized (#282).
    public var ambientStreaming = false
    /// Retained through card disappearance; recovery is inert until the app attaches its controller (#904).
    public var ambientController: AmbientListeningController? {
        didSet {
            ambientController?.reconnect.controller = ambientController
            ambientController?.reconnect.store = self
        }
    }
    /// Which overheard turns hosts should send (#398): `off`, `owner` or `everyone`; re-sent to each capable host as it
    /// reaches ready. Sends to one host run in order, so the last choice is the one it keeps.
    public private(set) var overheardScope = "off"
    @ObservationIgnored var overheardScopeSends: [HostEndpoint.Identifier: Task<Void, Never>] = [:]
    /// Told when a host says this device's ambient stream took listening over from another device (#366), with
    /// that device's class. The ambient card hands it to its controller.
    @ObservationIgnored public var onAmbientMovedHere: (@MainActor (HostEndpoint.Identifier, String?) -> Void)?
    /// Hosts that said RightyO does not recognise the owner's voice on this device's input (rightyo#164), until they
    /// say it does, the device starts a new stream, or the host is removed.
    public private(set) var ownerVoiceUnrecognized: Set<HostEndpoint.Identifier> = []
    /// The latest paste request a Mac refused (#608), so the station can put the paste back on its card with the
    /// reason. The conversation line and the announcement are `noteRefusal`'s and `onRequestRefusal`'s.
    public private(set) var lastPasteRefusal: PasteRefusal?
    /// Each host's last doctor summary (#614), asked for when its connection reaches ready and on request from Mac
    /// Setup; kept until the host is removed, so a host that drops still shows what it last reported.
    public private(set) var health: [HostEndpoint.Identifier: HostHealthReading] = [:]
    /// Each host's last `media_mode` for this device's stream (#612). A host keeps media mode per connection, so it
    /// is forgotten whenever that connection stops being ready or the host is removed.
    public private(set) var mediaMode: [HostEndpoint.Identifier: MediaModeStatus] = [:]
    /// Each host's last `duck_mode` for this device's stream (#735), kept and forgotten exactly like `mediaMode`.
    public private(set) var duckMode: [HostEndpoint.Identifier: DuckModeStatus] = [:]
    /// Each host's privacy switch state on this side (#735 S-6): a tap waiting for its notice, and whether the host
    /// stopped listening after confirming privacy. Reset by any `duck_mode` notice; dropped with `duckMode`.
    public private(set) var privacyLocal: [HostEndpoint.Identifier: PrivacySwitchLocal] = [:]
    /// This device's current input route kind for `ambient_input` (rightyo#164); replaceable in tests.
    @ObservationIgnored var inputRoute: @MainActor () async -> String? = { HostConnectionStore.currentInputRoute() }

    /// Bumped on every target selection, per host, so an ambient stream ends on any target change (#203).
    private var selectionSerials: [HostEndpoint.Identifier: UInt64] = [:]
    /// Independent confirmation tokens also retire older overlapping reauthorizations (#904).
    private var selectionRequests: [HostEndpoint.Identifier: UUID] = [:]
    /// The target each host last confirmed through `selectTarget`, the one its connection addresses audio to.
    /// Ambient bindings exist only for it (#218).
    private var selectedTargets: [HostEndpoint.Identifier: String] = [:]

    @ObservationIgnored private var connections: [HostEndpoint.Identifier: HostConnection] = [:]
    @ObservationIgnored private var tokens: [HostEndpoint.Identifier: UUID] = [:]
    @ObservationIgnored private var retiredBarriers: [HostEndpoint.Identifier: Task<Void, Never>] = [:]
    @ObservationIgnored private let connector: any WebSocketConnecting
    @ObservationIgnored private let schedule: ReconnectSchedule
    @ObservationIgnored private let pongTimeout: Duration
    @ObservationIgnored private let negotiationTimeout: Duration
    @ObservationIgnored private let deadlineSleep: HostConnection.Sleep
    @ObservationIgnored private let negotiationScheduler: HostConnection.DeadlineScheduler?
    @ObservationIgnored private let monotonicNow: HostConnection.MonotonicNow
    @ObservationIgnored private let wallNow: HostConnection.WallNow
    @ObservationIgnored private let sleep: HostConnection.Sleep
    @ObservationIgnored private let jitter: HostConnection.Jitter
    @ObservationIgnored private var pathMonitor: NWPathMonitor?
    @ObservationIgnored private var receivedInitialPath = false
    @ObservationIgnored private var diagnosticsFlush: Task<Void, Never>?
    /// The device diagnostics log (#234). Connection changes are recorded into it, and its batches go to the first
    /// ready host that advertises `device_diagnostics`; none goes anywhere else. Nil records and sends nothing.
    @ObservationIgnored public var diagnostics: DeviceDiagnostics? {
        didSet {
            diagnostics?.onPending = { [weak self] in self?.scheduleDiagnosticsFlush() }
            scheduleDiagnosticsFlush()
        }
    }

    public var hosts: [HostConnectionSnapshot] { order.compactMap { snapshots[$0] } }
    public init(
        connector: any WebSocketConnecting = URLSessionWebSocketConnector(),
        schedule: ReconnectSchedule = ReconnectSchedule(),
        pongTimeout: Duration = .seconds(5),
        negotiationTimeout: Duration = .seconds(10),
        deadlineSleep: @escaping HostConnection.Sleep = { try await Task.sleep(for: $0) },
        negotiationScheduler: HostConnection.DeadlineScheduler? = nil,
        monotonicNow: @escaping HostConnection.MonotonicNow = { ContinuousClock().now },
        wallNow: @escaping HostConnection.WallNow = {
            Int64((Date().timeIntervalSince1970 * 1_000).rounded(.down))
        },
        sleep: @escaping HostConnection.Sleep = { try await Task.sleep(for: $0) },
        jitter: @escaping HostConnection.Jitter = { Double.random(in: 0...1) }
    ) {
        self.connector = connector
        self.schedule = schedule
        self.pongTimeout = pongTimeout
        self.negotiationTimeout = negotiationTimeout
        self.deadlineSleep = deadlineSleep
        self.negotiationScheduler = negotiationScheduler
        self.monotonicNow = monotonicNow
        self.wallNow = wallNow
        self.sleep = sleep
        self.jitter = jitter
        if connector is URLSessionWebSocketConnector {
            let monitor = NWPathMonitor()
            pathMonitor = monitor
            monitor.pathUpdateHandler = { [weak self] _ in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    if self.receivedInitialPath { await self.networkPathChanged() }
                    self.receivedInitialPath = true
                }
            }
            monitor.start(queue: DispatchQueue(label: "hail.network-path"))
        }
    }

    deinit { pathMonitor?.cancel() }
}

extension HostConnectionStore {
    public func upsert(_ endpoint: HostEndpoint) async {
        if snapshots[endpoint.id]?.endpoint == endpoint { return }
        let restoring = ambientController?.reconnect.refreshEndpoint(
            endpoint, previous: snapshots[endpoint.id], store: self
        ) == true
        if !restoring { ambientController?.reconnect.veto(.endpointChanged, host: endpoint.id) }
        conversation.forgetHeardTurns(endpoint.id)
        let existing = connections.removeValue(forKey: endpoint.id)
        if restoring {
            selectedTargets[endpoint.id] = nil
            selectionRequests[endpoint.id] = nil
        } else { forgetSelection(endpoint.id) }
        let retainedBarrier = retiredBarriers.removeValue(forKey: endpoint.id)
        tokens[endpoint.id] = nil
        let inheritedBarrier = existing.map(drainingTransportBarrier(for:)) ?? retainedBarrier
        let connectionConnector = inheritedBarrier.map { barrier -> any WebSocketConnecting in
            SerializedWebSocketConnector(predecessor: barrier, base: connector)
        } ?? connector
        let token = UUID()
        tokens[endpoint.id] = token
        snapshots[endpoint.id] = HostConnectionSnapshot(endpoint: endpoint)
        if !order.contains(endpoint.id) { order.append(endpoint.id) }
        let connection = await makeConnection(endpoint, connector: connectionConnector, token: token)
        guard tokens[endpoint.id] == token else { await connection.disconnect(); return }
        connections[endpoint.id] = connection
        if restoring { await connection.connect() }
    }
    private func makeConnection(_ endpoint: HostEndpoint, connector connectionConnector: any WebSocketConnecting,
                                token: UUID) async -> HostConnection {
        let connection = HostConnection(
            endpoint: endpoint,
            connector: connectionConnector,
            schedule: schedule,
            pongTimeout: pongTimeout,
            negotiationTimeout: negotiationTimeout,
            deadlineSleep: deadlineSleep,
            negotiationScheduler: negotiationScheduler,
            monotonicNow: monotonicNow,
            wallNow: wallNow,
            reportsAmbientRefusals: true,
            transportLossObserver: { [weak self] generation, sending in
                await self?.transportLost(host: endpoint.id, generation: generation, sending: sending, token: token)
            },
            sleep: sleep,
            jitter: jitter,
            observer: { [weak self] snapshot in await self?.receive(snapshot, token: token) },
            replyObserver: { [weak self] event in await self?.receive(event, token: token) }
        )
        await connection.setReconnectPacing { [weak self] in
            await self?.ambientPacing(host: endpoint.id, token: token)
        }
        return connection
    }
    private func ambientPacing(host: HostEndpoint.Identifier, token: UUID) -> AmbientReconnectPacing? {
        guard tokens[host] == token, let reconnect = ambientController?.reconnect,
              reconnect.isPending, reconnect.binding?.hostID == host,
              reconnect.pacing?.isCancelled == false else { return nil }
        return reconnect.pacing
    }

    public func connect(_ id: HostEndpoint.Identifier) async {
        await connections[id]?.connect()
    }
    public func disconnect(_ id: HostEndpoint.Identifier) async {
        ambientController?.reconnect.veto(.explicitDisconnect, host: id)
        forgetSelection(id)
        await connections[id]?.disconnect()
    }
    /// Only reauthorization of the owner's existing destination uses `restoring` (#904).
    public func selectTarget(host id: HostEndpoint.Identifier, targetID: String,
                             restoring: Bool = false) async throws {
        if restoring, let current = ambientBinding(host: id, targetID: targetID),
           ambientController?.binding == current, ambientController?.isListening == true,
           ambientController?.reconnect.isPending == false { return }
        if !restoring { ambientController?.reconnect.block(.ownerSelection); forgetSelection(id) }
        selectedTargets[id] = nil
        let request = UUID()
        selectionRequests[id] = request
        let serial = selectionSerials[id]
        guard let connection = connections[id] else { throw HostConnectionFailure.notReady }
        do { try await connection.selectTarget(targetID) } catch {
            if selectionRequests[id] == request {
                selectionFailed(error, host: id, restoring: restoring, on: connection)
            }
            throw error
        }
        // A later selection, endpoint change or removal owns the outcome.
        if selectionSerials[id] == serial, selectionRequests[id] == request, connections[id] === connection {
            selectedTargets[id] = targetID
            ambientController?.reconnect.restore(store: self)
        }
    }
    private func selectionFailed(_ error: any Error, host id: HostEndpoint.Identifier,
                                 restoring: Bool, on connection: HostConnection) {
        guard let snapshot = snapshots[id], connections[id] === connection,
              let reconnect = ambientController?.reconnect else { return }
        guard restoring else { return reconnect.veto(.bindingChanged, host: id) }
        reconnect.selectionFailed(error, snapshot: snapshot, store: self)
    }
    func retryAmbientTransport(host id: HostEndpoint.Identifier, generation: UUID) async -> Bool {
        guard let connection = connections[id], snapshots[id]?.connectionGeneration == generation,
              privacyLocal[id]?.request == nil,
              ambientController?.reconnect.allowsTransportRetry(host: id, generation: generation) == true
        else { return false }
        return await connection.retryAmbientTransport(generation: generation)
    }
    /// The ambient binding for a destination, or nil unless the host is ready, advertises `stream_audio`, and
    /// `targetID` is the target its connection has confirmed: the connection addresses every segment to that
    /// selection, so a binding for any other target would misstate where audio goes (#218).
    public func ambientBinding(host id: HostEndpoint.Identifier, targetID: String) -> AmbientAudioBinding? {
        guard selectedTargets[id] == targetID, let snapshot = snapshots[id], snapshot.state == .ready,
              snapshot.capabilities.contains(HostConnection.streamAudioCapability),
              !snapshot.receivedTargetList || snapshot.targets.contains(where: { $0.id == targetID && $0.alive })
        else { return nil }
        return AmbientAudioBinding(
            hostID: id, targetID: targetID, connectionGeneration: snapshot.connectionGeneration,
            selection: selectionSerials[id, default: 0]
        )
    }

    public func remove(_ id: HostEndpoint.Identifier) async {
        ambientController?.reconnect.veto(.endpointChanged, host: id)
        conversation.forgetHeardTurns(id)
        tokens[id] = nil
        forgetSelection(id)
        let connection = connections.removeValue(forKey: id)
        let barrier = connection.map(drainingTransportBarrier(for:)) ?? retiredBarriers[id]
        if let barrier { retiredBarriers[id] = barrier }
        (snapshots[id], health[id]) = (nil, nil)
        ownerVoiceUnrecognized.remove(id)
        forgetModes(id)
        order.removeAll { $0 == id }
    }
    /// Every selection change, endpoint change or removal invalidates outstanding bindings for the host.
    private func forgetSelection(_ id: HostEndpoint.Identifier) {
        selectionSerials[id, default: 0] &+= 1
        selectedTargets[id] = nil
        selectionRequests[id] = nil
    }

    private func transportLost(host: HostEndpoint.Identifier, generation: UUID, sending: Bool, token: UUID) {
        guard tokens[host] == token, let snapshot = snapshots[host],
              snapshot.connectionGeneration == generation else { return }
        // A failed reassert send must settle as privacy failure, even if its notice arrived first.
        // Receive loss during confirmation remains a distinct transport flap and retains retry pacing.
        if sending, ambientController?.reconnect.privacyConfirmation.sendFailed(host: host, generation: generation)
            == true { return }
        ambientController?.reconnect.drop(snapshot, store: self)
    }

    private func receive(_ snapshot: HostConnectionSnapshot, token: UUID) {
        guard tokens[snapshot.id] == token else { return }
        let old = snapshots[snapshot.id]
        let previous = old?.state
        ambientController?.reconnect.receive(snapshot, previous: old, store: self)
        if snapshot.state != .ready { selectedTargets[snapshot.id] = nil; selectionRequests[snapshot.id] = nil }
        if snapshot.state != .ready || snapshots[snapshot.id]?.connectionGeneration != snapshot.connectionGeneration {
            conversation.forgetHeardTurns(snapshot.id)
        }
        snapshots[snapshot.id] = snapshot
        recordDiagnostics(from: previous, to: snapshot.state)
        if snapshot.state == .ready, previous != .ready { hostBecameReady(snapshot.id) }
        if snapshot.state != .ready { forgetModes(snapshot.id) }
    }

    private func acceptConfirmedResume(on host: HostEndpoint.Identifier) async {
        guard let proof = ambientController?.reconnect.acceptance, proof.binding.hostID == host,
              let connection = connections[host], await connection.hasConfirmed(proof) else { return }
        ambientController?.reconnect.accepted(proof)
    }

    private func receive(_ event: HostReplyEvent, token: UUID) async {
        guard tokens[event.endpointID] == token else { return }
        // The receive loop awaits this callback before processing the next frame. Check the exact probe's
        // pong on the connection actor, so a stalled polling waiter cannot misclassify a post-pong refusal.
        if HostNoticeOrigin.streamID != nil { await acceptConfirmedResume(on: event.endpointID) }
        guard tokens[event.endpointID] == token else { return }
        if receiveAmbientNotice(event) { return }
        segmentWiring?.receive(event)
        replyFrames.append(event)
        conversation.noteReply(event, selected: selectedTargets[event.endpointID],
                               scope: addressScope(event.endpointID))
        onReplyFrame?(event)
        if replyFrames.count > Self.replyFrameLimit {
            replyFrames.removeFirst(replyFrames.count - Self.replyFrameLimit)
        }
    }
}

/// The host's doctor summary (#614).
extension HostConnectionStore {
    /// A connection just reached ready: the current overheard scope (#398) and a health request (#614) go to it.
    func hostBecameReady(_ id: HostEndpoint.Identifier) {
        applyOverheardScope(to: id)
        requestHealth(id)
    }

    /// Asks a ready host that advertised `host_health` for its doctor summary (#614); others are left alone.
    public func requestHealth(_ id: HostEndpoint.Identifier) {
        guard let connection = connections[id], snapshots[id]?.state == .ready,
              snapshots[id]?.capabilities.contains(HostHealth.capability) == true else { return }
        Task { try? await connection.requestHealth() }
    }
}

/// Reconnect nudges: the station's connection check (#385) and scene activation.
extension HostConnectionStore {
    /// The station's connection check (#385) for `ids` only: as `sceneBecameActive`, a ready host is pinged and one
    /// trying to recover skips its backoff. A host disconnected in Mac Setup stays disconnected.
    public func checkConnection(_ ids: [HostEndpoint.Identifier]) async {
        for id in ids { await connections[id]?.foregrounded() }
    }

    /// Active hosts are pinged; hosts already trying to recover skip their backoff and reconnect now.
    public func sceneBecameActive() async {
        for id in order {
            await connections[id]?.foregrounded()
        }
    }

    func networkPathChanged() async {
        for id in order { await connections[id]?.networkPathChanged() }
    }
}

/// Ambient notices are not replies: neither joins the reply list.
extension HostConnectionStore {
    /// True when `event` was an ambient notice, now handled. A take-over notice (#366) goes to ambient listening; the
    /// user's own ambient request (#318) joins the chat as theirs, like a tap-to-talk send.
    func receiveAmbientNotice(_ event: HostReplyEvent) -> Bool {
        switch event.frame.payload {
        case .control(.ambientMovedHere(let from)):
            onAmbientMovedHere?(event.endpointID, from)
        case .control(.ambientHeard(let targetID, let text, let turn)):
            let entryID = conversation.noteSent(
                text, endpointID: event.endpointID, targetID: targetID,
                targets: snapshots[event.endpointID]?.targets ?? [], scope: addressScope(event.endpointID)
            )
            conversation.recordHeardTurn(turn, for: entryID)
            segmentWiring?.ambientRequestAdmitted(from: event.endpointID)
        case .control(.ambientOverheard(let targetID, let text, let speaker, let name)):
            conversation.noteOverheard(
                text, owner: speaker == "owner", name: name, endpointID: event.endpointID, targetID: targetID
            )
        case .control(.healthReport(let report)):
            let generation = snapshots[event.endpointID]?.connectionGeneration
            health[event.endpointID] = HostHealthReading(report: report, connectionGeneration: generation)
        case .control(.error(let code, let message, let turn)) where code.isRequestRefusal:
            receiveRequestRefusal(code, message: message, turn: turn, from: event.endpointID)
        case .control(.error(let code, let message, _)) where message.hasPrefix("ambient"):
            ambientController?.receiveAmbientRefusal(
                HostConnectionFailure.remote("\(code.rawValue): \(message)"), host: event.endpointID,
                generation: HostNoticeOrigin.generation, streamID: HostNoticeOrigin.streamID
            )
        case .control(.ownerVoice(let state)):
            if state == "unrecognized" {
                ownerVoiceUnrecognized.insert(event.endpointID)
            } else {
                ownerVoiceUnrecognized.remove(event.endpointID)
            }
        default:
            return receiveModeNotice(event)
        }
        return true
    }

    /// Marks only a correlated heard turn, then retains the shared notice, announcement and paste handling.
    private func receiveRequestRefusal(
        _ code: ErrorCode, message: String, turn: UUID?, from endpointID: HostEndpoint.Identifier
    ) {
        if code == .voiceRouteRefused { conversation.noteHeardRefused(turn, endpointID: endpointID) }
        if let snapshot = snapshots[endpointID] {
            ambientController?.reconnect.privacyConfirmation.receive(
                on: false, host: snapshot.id, generation: HostNoticeOrigin.generation
            )
        }
        // The one chat line and the one announcement for every request refusal, whatever its code.
        conversation.noteRefusal(message, endpointID: endpointID,
                                 targetID: selectedTargets[endpointID] ?? "")
        onRequestRefusal?(message)
        // A refused paste (#608) also marks its pending turn and is offered back on the card; no second line.
        if code == .pasteRefused,
           let refused = conversation.notePasteRefused(message, endpointID: endpointID) {
            lastPasteRefusal = PasteRefusal(endpointID: endpointID, entryID: refused.id, pasted: refused.text,
                                            message: message)
        }
    }

    /// True when `event` was a host's media mode (#612) or duck mode (#735) state for this device's stream, now kept.
    private func receiveModeNotice(_ event: HostReplyEvent) -> Bool {
        switch event.frame.payload {
        case .control(.mediaMode(let on, let reason, let expires)):
            mediaMode[event.endpointID] = MediaModeStatus(on: on, reason: reason, expiresMilliseconds: expires)
        case .control(.duckMode(let on, let reason, let expires)):
            if let origin = HostNoticeOrigin.generation,
               origin != snapshots[event.endpointID]?.connectionGeneration { return true }
            duckMode[event.endpointID] = DuckModeStatus(on: on, reason: reason, expiresMilliseconds: expires)
            if let request = privacyLocal[event.endpointID]?.request,
               request.on != on || (on && duckMode[event.endpointID]?.isOn() != true) {
                ambientController?.reconnect.veto(.privacy, host: event.endpointID)
            }
            ambientController?.reconnect.confirmedPrivacy(on: duckMode[event.endpointID]?.isOn() == true,
                                                         host: event.endpointID)
            privacyLocal[event.endpointID] = nil
            if let snapshot = snapshots[event.endpointID] {
                ambientController?.reconnect.privacyConfirmation.receive(
                    on: duckMode[event.endpointID]?.isOn() == true, host: snapshot.id,
                    generation: HostNoticeOrigin.generation
                )
            }
        default:
            return false
        }
        return true
    }
}

/// Ambient audio (#203), with the owner voice status and input route around a stream's start (rightyo#164).
extension HostConnectionStore {
    /// Sends one ambient segment to the host and target the binding names (#203). The binding is authoritative:
    /// it must still be the current one for the connection's confirmed target, so a reconnect, an endpoint change
    /// or any target selection since it was taken makes every further segment throw and the streamer releases
    /// the mic.
    public func sendAudio(_ audio: AudioPayload, to binding: AmbientAudioBinding) async throws {
        guard AmbientSendAdmission.isCurrent,
              ambientBinding(host: binding.hostID, targetID: binding.targetID) == binding,
              let connection = connections[binding.hostID] else { throw HostConnectionFailure.notReady }
        if audio.sequence == 0 {
            await startingStream(on: connection, host: binding.hostID)
            // The route send suspended: a selection or endpoint change since then owns the connection, so this
            // binding's audio must not reach its new target (#491 review).
            guard AmbientSendAdmission.isCurrent,
                  ambientBinding(host: binding.hostID, targetID: binding.targetID) == binding,
                  connections[binding.hostID] === connection else { throw HostConnectionFailure.notReady }
        }
        do {
            try await connection.sendAudio(audio, bindingGeneration: binding.connectionGeneration)
        } catch {
            // A send can observe the refusal before its ordered notice callback reaches the controller.
            await acceptConfirmedResume(on: binding.hostID)
            ambientController?.reconnect.sendFailed(error, audio: audio, binding: binding, store: self)
            notePrivateStop(error, binding: binding)
            throw error
        }
        if audio.isResume, ambientController?.ownsAudio(audio.streamID, binding: binding) == true {
            ambientController?.reconnect.confirmAcceptance(of: audio, binding: binding, on: connection)
        }
        if audio.sequence > 0 { privacyLocal[binding.hostID]?.listeningStopped = false }
    }

    /// A new ambient stream starts a new RightyO session, so an earlier "not recognised" no longer holds; and a host
    /// that accepts it is told which kind of input this stream comes from, before its first segment. A failed route
    /// send never stops the audio: it is only for attribution.
    func startingStream(on connection: HostConnection, host: HostEndpoint.Identifier) async {
        ownerVoiceUnrecognized.remove(host)
        guard snapshots[host]?.capabilities.contains(AmbientInput.capability) == true,
              let route = Self.sendableRoute(await inputRoute()) else { return }
        try? await connection.sendAmbientInput(route)
    }

    /// The route kinds every `ambient_input_route` host accepts: the vocabulary as first shipped (#488). The diagnostic
    /// list it came from may grow, and an older host refuses a token it does not know, so anything else is sent as
    /// `other`; no input at all sends nothing.
    static let ambientInputRoutesV1: Set<String> = [
        "none", "built_in_mic", "built_in_speaker", "built_in_receiver", "headphones", "headset_mic", "line_in",
        "line_out", "bluetooth_a2dp", "bluetooth_hfp", "bluetooth_le", "airplay", "hdmi", "car_audio", "usb_audio",
        "other"
    ]

    static func sendableRoute(_ route: String?) -> String? {
        route.map { ambientInputRoutesV1.contains($0) ? $0 : "other" }
    }

    /// The current audio input's route kind, as the diagnostics name it; nil where there is no audio session.
    static func currentInputRoute() -> String? {
        #if os(iOS)
        AVAudioSession.sharedInstance().currentRoute.inputs.first.map { DeviceDiagnostics.route($0.portType) }
        #else
        nil
        #endif
    }
}

/// Overheard remarks (#398): the scope the user chose, sent to every ready host that supports it. A host starts each
/// connection at `off`, but the current choice, `off` included, is sent again whenever a connection reaches ready: it
/// lands after any older choice still queued for that host, so a stale scope can never outlive a newer `off`.
extension HostConnectionStore {
    public func setOverheardScope(_ scope: String) {
        guard let scope = AmbientOverheard.scope(scope), scope != overheardScope else { return }
        overheardScope = scope
        for id in order where snapshots[id]?.state == .ready { sendCurrentScope(to: id) }
    }

    func applyOverheardScope(to id: HostEndpoint.Identifier) {
        sendCurrentScope(to: id)
    }

    /// Chained per host, and each send reads the choice when it runs, not when it was queued: a send delayed across a
    /// reconnect or overtaken by a newer choice carries the newest one, so a stale broader scope is never sent.
    private func sendCurrentScope(to id: HostEndpoint.Identifier) {
        guard let connection = connections[id],
              snapshots[id]?.capabilities.contains(AmbientOverheard.capability) == true else { return }
        let previous = overheardScopeSends[id]
        overheardScopeSends[id] = Task { [weak self] in
            await previous?.value
            guard let scope = self?.overheardScope else { return }
            try? await connection.sendOverheardScope(scope)
        }
    }
}

/// The privacy switch (#735 S-6): the device turns privacy on or off for its own stream; the station shows only what the
/// host confirmed.
extension HostConnectionStore {
    /// A host keeps media mode, privacy and a switch's request per connection: forgotten together when it stops being
    /// ready or the host is removed, so nothing confirmed outlives the connection it was confirmed on.
    func forgetModes(_ id: HostEndpoint.Identifier) {
        (mediaMode[id], duckMode[id], privacyLocal[id]) = (nil, nil, nil)
    }

    /// Jarvis's "Privacy on · listening unavailable": the host confirmed privacy on this connection, then ended the
    /// ambient stream (`not_allowed: ambient stopped:` or `ambient unavailable:`), as it does when no child can keep
    /// privacy. Noted only for the connection generation the privacy was confirmed on.
    func notePrivateStop(_ error: any Error, binding: AmbientAudioBinding) {
        guard case HostConnectionFailure.remote(let message) = error,
              ["not_allowed: ambient stopped:", "not_allowed: ambient unavailable:"].contains(where: message.hasPrefix),
              duckMode[binding.hostID]?.isOn() == true,
              snapshots[binding.hostID]?.connectionGeneration == binding.connectionGeneration else { return }
        privacyLocal[binding.hostID, default: PrivacySwitchLocal()].listeningStopped = true
    }

    /// Whether the station offers the switch for `id`: a ready host that advertised `set_privacy`. An older host never.
    public func canSetPrivacy(_ id: HostEndpoint.Identifier) -> Bool {
        guard let snapshot = snapshots[id], snapshot.state == .ready else { return false }
        return snapshot.capabilities.contains(DuckMode.privacySwitchCapability)
    }

    /// Whether the station card shows the switch: while this device is listening, on a host that takes it; and, the
    /// one exception (Jarvis), while privacy is confirmed on but the host stopped listening, so it can be turned off.
    public func showsPrivacySwitch(_ id: HostEndpoint.Identifier, listening: Bool, now: Date = Date()) -> Bool {
        guard canSetPrivacy(id) else { return false }
        return listening || privacySwitch(id, listening: false, now: now).shown == .privateListeningUnavailable
    }

    /// What the switch shows for `id` at `now`: private only once the host's notice confirmed it on a live connection.
    public func privacySwitch(_ id: HostEndpoint.Identifier, listening: Bool = true,
                              now: Date = Date()) -> PrivacySwitchStatus {
        let local = privacyLocal[id]
        return PrivacySwitchStatus(ready: snapshots[id]?.state == .ready, duck: duckMode[id], requested: local?.request,
                                   listeningStopped: !listening && local?.listeningStopped == true, now: now)
    }

    /// Asks host `id` to turn privacy on or off for this device's stream. The switch waits (not private) until the
    /// host's `duck_mode` notice arrives; the tap itself never changes the state shown.
    public func setPrivacy(on: Bool, host id: HostEndpoint.Identifier) async throws {
        // A healthy switch request becomes pre-drop state only when THIS host confirms it. It is not a veto
        // yet; drop() blocks an unsettled request. Gap taps and failed sends latch until an owner start.
        if snapshots[id]?.state != .ready || ambientController?.reconnect.isPending == true
            || ambientController?.pausedReason != nil {
            ambientController?.reconnect.veto(.privacy, host: id)
        }
        let request = PrivacyRequest(on: on)
        privacyLocal[id, default: PrivacySwitchLocal()].request = request
        do {
            try await sendPrivacy(on: on, host: id)
        } catch {
            ambientController?.reconnect.veto(.privacy, host: id)
            if privacyLocal[id]?.request == request { privacyLocal[id]?.request = nil }
            throw error
        }
    }

    /// Restore-originated reassertion uses the same control send, without an owner tap or switch request.
    func reassertPrivacy(for binding: AmbientAudioBinding) async throws {
        guard ambientBinding(host: binding.hostID, targetID: binding.targetID) == binding else {
            throw HostConnectionFailure.notReady
        }
        try await sendPrivacy(on: true, host: binding.hostID)
    }

    private func sendPrivacy(on: Bool, host id: HostEndpoint.Identifier) async throws {
        guard let connection = connections[id] else { throw HostConnectionFailure.notReady }
        try await connection.sendSetPrivacy(on: on)
    }
}

/// Text and Escape to a target; sent text joins the station chat (#288).
extension HostConnectionStore {
    /// `pasted` (#608) rides with `text`, which may then be empty; the transcript shows both once sent, the paste pending
    /// until a reply for the destination arrives or the Mac refuses it.
    public func sendFinalText(
        _ text: String, pasted: PastedDraft? = nil, host id: HostEndpoint.Identifier, targetID: String
    ) async throws {
        guard let connection = connections[id] else { throw HostConnectionFailure.notReady }
        // The address and the request's own entry are recorded under the scope the request goes out on, before the
        // send can suspend (#636): a reply that comes back first is placed, and shows after its request. Both are taken
        // back if the send fails.
        let address = conversation.address(text, endpointID: id, targetID: targetID,
                                           targets: snapshots[id]?.targets ?? [], scope: addressScope(id))
        let sent = conversation.noteSent(text, pasted: pasted?.text, endpointID: id, targetID: targetID)
        do {
            if let pasted {
                try await connection.sendFinalText(text, pasted: pasted, to: targetID)
            } else {
                try await connection.sendFinalText(text, to: targetID)
            }
        } catch {
            conversation.retractAddress(address)
            conversation.retractSent(sent)
            throw error
        }
    }

    /// Whether the destination takes pasted text (#608): the Mac advertises `pasted_text` and the target is of a kind
    /// that may (the Mac still checks a tmux pane is an agent, and refuses without dropping the connection).
    public func acceptsPaste(host id: HostEndpoint.Identifier, targetID: String) -> Bool {
        guard let snapshot = snapshots[id], snapshot.capabilities.contains(PastedText.capability) else { return false }
        let kind = snapshot.targets.first { $0.id == targetID }?.kind
        return kind.map(PastedDraft.pasteTargetKinds.contains) == true
    }

    /// What an addressed request is bound to (#636): the connection and selection it was sent on, as the host binds
    /// its reply claim, so any reselection or reconnect retires it. Nil without a connection.
    func addressScope(_ id: HostEndpoint.Identifier) -> String? {
        snapshots[id].map { "\($0.connectionGeneration)|\(selectionSerials[id, default: 0])" }
    }
    public func sendEscape(host id: HostEndpoint.Identifier, targetID: String) async throws {
        guard let connection = connections[id] else { throw HostConnectionFailure.notReady }
        try await connection.sendEscape(to: targetID)
    }
}

/// Device diagnostics (#234): recording connection changes and sending batches.
extension HostConnectionStore {
    /// Each change of connection state, with the reconnect attempt; reaching ready also records `app_info`, so
    /// every host session starts with the build, and sends what was buffered while offline.
    func recordDiagnostics(from previous: HostConnectionState?, to state: HostConnectionState) {
        guard let diagnostics, previous.map(Self.stateToken) != Self.stateToken(state) else { return }
        var fields: [DiagnosticField: DiagnosticValue] = [.state: .token(Self.stateToken(state))]
        if case .reconnecting(let attempt, _) = state { fields[.attempt] = .integer(Int64(attempt)) }
        diagnostics.record(.connectionState, fields)
        if state == .ready {
            diagnostics.record(.appInfo, DeviceDiagnostics.appInfo())
            scheduleDiagnosticsFlush(after: .zero)
        }
    }

    /// True when some ready host advertises `device_diagnostics`, so the toggle can say whether anyone collects.
    public var diagnosticsCollectingHost: HostConnectionSnapshot? {
        hosts.first { $0.state == .ready && $0.capabilities.contains(DiagnosticLimits.capability) }
    }

    static func stateToken(_ state: HostConnectionState) -> String {
        switch state {
        case .disconnected: "disconnected"
        case .connecting: "connecting"
        case .negotiating: "negotiating"
        case .ready: "ready"
        case .reconnecting: "reconnecting"
        case .failed: "failed"
        }
    }

    /// One pending send at a time. Each sends the batch the log's budget allows to the first collecting host,
    /// then reschedules while anything remains; a failed send puts the batch back for the next connection.
    func scheduleDiagnosticsFlush(after delay: Duration = .seconds(2)) {
        guard diagnosticsFlush == nil, diagnostics?.hasPending == true, diagnosticsCollectingHost != nil else { return }
        let sleep = sleep
        diagnosticsFlush = Task { [weak self] in
            try? await sleep(delay)
            await self?.flushDiagnostics()
        }
    }

    private func flushDiagnostics() async {
        diagnosticsFlush = nil
        guard let diagnostics, let host = diagnosticsCollectingHost, let connection = connections[host.id] else {
            return
        }
        guard let batch = diagnostics.nextBatch() else {
            if diagnostics.hasPending { scheduleDiagnosticsFlush(after: .seconds(5)) }
            return
        }
        // The toggle's promise: once logging is off, nothing taken before is sent or requeued.
        guard diagnostics.isCurrent(batch) else { return }
        do {
            try await connection.sendDiagnostics(batch.events)
        } catch {
            diagnostics.requeue(batch)
            return
        }
        scheduleDiagnosticsFlush()
    }
}

/// One destination's ambient-listening identity: host, target, socket generation and selection serial. Any change
/// is a different binding, and the store refuses segments for a stale one.
public struct AmbientAudioBinding: Hashable, Sendable {
    public let hostID: HostEndpoint.Identifier
    public let targetID: String
    public let connectionGeneration: UUID
    let selection: UInt64
}

/// Scene state as the ambient toggle needs it; the app maps SwiftUI's `ScenePhase` onto it.
public enum AmbientScene: Sendable { case active, inactive, background }

/// The "Ambient listening" toggle (#203). Off on every launch: a binding change (target, reconnect), a send
/// failure or the microphone ending turns it off, and the user must turn it on again. A guarded transport restore
/// (#904) keeps capture alive across a drop, discarding gap audio. Another exception (#287):
/// when the host ends the stream for a transient reason (idle, its listener exiting), the microphone keeps running
/// and a fresh stream starts after a backoff, a few times at most. Once streaming, it keeps running when the app
/// leaves the foreground (#282); it only starts in the foreground. Audio is never logged; `stopReason` carries
/// only the cause.
@MainActor
@Observable
public final class AmbientListeningController {
    public typealias Send = @Sendable (AudioPayload, AmbientAudioBinding) async throws -> Void
    /// Activates the audio session and builds a streamer around `send`; the controller starts it.
    public typealias MakeStreamer = @MainActor (@escaping AmbientAudioStreamer.Send) async throws
        -> AmbientAudioStreamer

    /// The toggle: true from the user's request until any stop.
    public private(set) var isOn = false
    /// True only while microphone audio is actually streaming.
    public private(set) var isListening = false {
        didSet { reportActivity() }
    }
    /// Told whenever "listening or paused" changes, without a view update, so state that must hold in the
    /// background (the kept destination authorization, #282) follows it there too. A pause (#445) keeps it true:
    /// the destination must survive a call or Siri in the background for the resume to have somewhere to go.
    @ObservationIgnored public var onListeningChange: (@MainActor (Bool) -> Void)?
    /// Told the reason whenever listening stops without the user turning it off, so the app can notify (#287).
    @ObservationIgnored public var onUnexpectedStop: (@MainActor (String) -> Void)?
    public let reconnect = AmbientListeningReconnect()
    public private(set) var stopReason: String?
    public private(set) var binding: AmbientAudioBinding?
    /// Ambient take-over (#366): where listening went after another device took it (not an error), or, briefly,
    /// where it came from after this device took it. Nil otherwise.
    public private(set) var handoff: AmbientHandoff?
    /// Set while another app holds the microphone (#445): listening is still on and resumes by itself.
    public private(set) var pausedReason: String? {
        didSet { reportActivity() }
    }

    @ObservationIgnored private let send: Send
    @ObservationIgnored private let requestPermission: @MainActor () async -> Bool
    @ObservationIgnored private let makeStreamer: MakeStreamer
    @ObservationIgnored private let releaseSession: @MainActor () async -> Void
    @ObservationIgnored private var streamer: AmbientAudioStreamer?
    @ObservationIgnored private var session = UUID()
    @ObservationIgnored private var scene = AmbientScene.active
    @ObservationIgnored private var awaitingPermission = false
    @ObservationIgnored private var pendingStart = false
    @ObservationIgnored private var sendFailure: String?
    /// The send failure's cause as a token (`host_refused` with the host's code, or `send_failed`) for diagnostics.
    @ObservationIgnored private var sendFailureCause: (cause: String, code: String?)?
    /// Set when the host refused a segment because another device took listening over (#366).
    @ObservationIgnored private var movedAway: AmbientHandoff?
    /// Identifies the current "listening here now" confirmation, so only its own timer clears it.
    @ObservationIgnored private var confirmation = UUID()
    /// The device diagnostics log (#234): ambient start, stop with its cause, and host refusals. Never audio.
    @ObservationIgnored public var diagnostics: DeviceDiagnostics?
    /// The session that most recently began activating the audio session. Only it may release the audio session,
    /// so a slow teardown of an earlier session cannot deactivate the one a fast off→on started (#218).
    @ObservationIgnored private var activation: UUID?
    /// The release in flight, if any; a new activation waits for it so the two never interleave.
    @ObservationIgnored private var pendingRelease: Task<Void, Never>?
    @ObservationIgnored private let notificationCenter: NotificationCenter
    /// Watches for capture ended by the system, so the toggle drops before queued audio finishes draining.
    @ObservationIgnored private var systemEndObserver: (any NSObjectProtocol)?
    /// Nil in production: waits then call `Task.sleep(for:)` directly (#904).
    @ObservationIgnored private let sleep: (@Sendable (Duration) async throws -> Void)?
    @ObservationIgnored private let now: @Sendable () -> ContinuousClock.Instant
    /// Fresh streams started this session since the last quiet spell, and when the latest began (#287).
    @ObservationIgnored private var recoveries = 0
    @ObservationIgnored private var lastRecovery: ContinuousClock.Instant?
    /// The backoff in progress; ending the session cancels it so turning off never waits on it.
    @ObservationIgnored private var recoveryWait: Task<Void, any Error>?
    /// Resuming after another app took the microphone (#445): its retry task and interruption-ended observer.
    @ObservationIgnored private var resumer: AmbientResumer?
    @ObservationIgnored private var reportedActivity = false

    /// `notificationCenter` is where capture posts `AVAudioEngineCapture.endedBySystem`.
    public init(
        notificationCenter: NotificationCenter = .default,
        requestPermission: @escaping @MainActor () async -> Bool,
        makeStreamer: @escaping MakeStreamer,
        releaseSession: @escaping @MainActor () async -> Void,
        sleep: (@Sendable (Duration) async throws -> Void)? = nil,
        now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock().now },
        send: @escaping Send
    ) {
        self.notificationCenter = notificationCenter
        self.sleep = sleep
        self.now = now
        self.requestPermission = requestPermission
        self.makeStreamer = makeStreamer
        self.releaseSession = releaseSession
        self.send = send
    }

    public func turnOn(for binding: AmbientAudioBinding) async {
        guard !isOn, scene == .active else { return }
        reconnect.ownerStarted()
        let current = UUID()
        session = current
        isOn = true
        stopReason = nil
        handoff = nil
        movedAway = nil
        sendFailure = nil
        sendFailureCause = nil
        recoveries = 0
        lastRecovery = nil
        self.binding = binding
        // The permission alert makes the scene inactive, so only leaving for the background cancels here.
        awaitingPermission = true
        let granted = await requestPermission()
        awaitingPermission = false
        guard session == current else { return }
        guard granted else {
            return await end(current, reason: "Microphone access is off. Allow it in Settings to listen.",
                             cause: "permission_denied")
        }
        if scene == .active { await start(current) } else { pendingStart = true }
    }
}

extension AmbientListeningController {
    /// Opens a stream for `current`. A resume after an interruption (#445) waits for the foreground, and a
    /// failed one leaves listening paused for the next retry instead of ending it.
    @discardableResult
    private func start(_ current: UUID, resuming: Bool = false) async -> Bool {
        guard let binding else { return false }
        await pendingRelease?.value
        guard session == current else { return false }
        if resuming, scene != .active { pausedReason = Self.foregroundPausedStatus; return false }
        guard scene == .active else {
            await end(current, reason: "Stopped: Hailing Station left the foreground.", cause: "background")
            return false
        }
        activation = current
        do {
            let streamer = try await openStreamer(current, binding: binding)
            streamer.opensAsResume = resuming
            guard session == current, scene == .active else {
                await release(current)
                if resuming, session == current { pausedReason = Self.foregroundPausedStatus; return false }
                await end(current, reason: "Stopped: Hailing Station left the foreground.", cause: "background")
                return false
            }
            try streamer.start()
            self.streamer = streamer
            isListening = true
            pausedReason = nil
            diagnostics?.record(.ambientStart)
            observeSystemEnd(session: current)
            watch(streamer, session: current)
            return true
        } catch {
            await release(current)
            if !resuming {
                await end(current, reason: "Could not start listening: \(Self.describe(error))", cause: "start_failed")
            }
            return false
        }
    }

    private func end(_ current: UUID, reason: String?, cause: String, code: String? = nil) async {
        guard session == current, isOn else { return }
        let restoring = reconnect.isPending
        var fields: [DiagnosticField: DiagnosticValue] = [.reason: .token(cause)]
        if let code { fields[.code] = .token(code) }
        diagnostics?.record(.ambientStop, fields)
        if restoring { reconnect.finish(.failed, reason: movedAway == nil ? .startFailed : .movedAway) }
        session = UUID()
        reconnect.captureResumed()
        isOn = false
        isListening = false
        pendingStart = false
        awaitingPermission = false
        stopReason = reason
        binding = nil
        recoveryWait?.cancel()
        recoveryWait = nil
        resumer?.cancel()
        resumer = nil
        pausedReason = nil
        // Moved away (#366) is where listening went, not a failure: no alert, and "Listen here" brings it back.
        handoff = cause == "user" ? nil : movedAway.flatMap { reason == $0.status ? $0 : nil }
        movedAway = nil
        if cause != "user", !restoring, !reconnect.replacedAppliedNotice, handoff == nil, let reason {
            onUnexpectedStop?(reason)
        }
        if let systemEndObserver {
            notificationCenter.removeObserver(systemEndObserver)
            self.systemEndObserver = nil
        }
        guard let streamer else { return }
        self.streamer = nil
        await streamer.stop()
        await release(current)
    }
}

extension AmbientListeningController {
    private func watch(_ streamer: AmbientAudioStreamer, session current: UUID) {
        let streaming = withObservationTracking { streamer.isStreaming } onChange: { [weak self] in
            Task { @MainActor in self?.watch(streamer, session: current) }
        }
        // Only the current stream's end stops listening: a paused (#445) or already-replaced stream's does not.
        guard !streaming, isListening, session == current, pausedReason == nil,
              self.streamer === streamer else { return }
        Task {
            guard isListening, pausedReason == nil, self.streamer === streamer else { return }
            await end(current, reason: sendFailure ?? "Stopped: the microphone was interrupted or ended.",
                      cause: sendFailureCause?.cause ?? "capture_ended", code: sendFailureCause?.code)
        }
    }

    /// Only the live stream's failure counts: a stream replaced by a pause (#445) still draining is ignored.
    private func recordSendFailure(_ error: any Error, session current: UUID,
                                   from source: AmbientAudioStreamer?, streamID: UUID?) {
        guard AmbientSendAdmission.isCurrent, session == current, sendFailure == nil,
              let source, source === streamer, source.streamID == streamID else { return }
        if reconnect.isPending, Self.isTransportError(error) { return }
        movedAway = AmbientHandoff(refusal: error)
        if case HostConnectionFailure.remote = error, !Self.isTransient(error) {
            reconnect.refused(reason: movedAway == nil ? .startFailed : .movedAway,
                              streamID: streamID, binding: binding)
        }
        sendFailure = movedAway?.status ?? "Stopped: \(Self.describe(error))"
        sendFailureCause = Self.diagnosticCause(error)
        if let code = sendFailureCause?.code { diagnostics?.record(.hostRefusal, [.code: .token(code)]) }
    }

    /// Releases the audio session for `owner` unless a newer session has begun activating it since.
    private func release(_ owner: UUID) async {
        guard activation == owner else { return }
        activation = nil
        let releaseSession = releaseSession
        let task = Task { @MainActor in await releaseSession() }
        pendingRelease = task
        await task.value
    }

    static let interruptedReason = "Stopped: a call, Siri or an audio route change interrupted the microphone."

    /// A call, Siri or a route change ended capture: turn off now rather than after the backlog drains (#218).
    private func observeSystemEnd(session current: UUID) {
        systemEndObserver = notificationCenter.addObserver(
            forName: AVAudioEngineCapture.endedBySystem, object: nil, queue: nil
        ) { [weak self] note in
            let interrupted = note.userInfo?[AVAudioEngineCapture.endedCauseKey] as? String
                == AVAudioEngineCapture.interruptionCause
            // What ended it (#459): an interruption, a route change by its reason, or the engine stopping.
            let ended = note.userInfo?[AVAudioEngineCapture.endedReasonKey] as? String
            // Capture posts on the main thread: mark the pause before the ended stream's own watcher can run.
            if interrupted, Thread.isMainThread, let controller = self {
                MainActor.assumeIsolated { controller.markPaused(current) }
            }
            Task { @MainActor in
                if interrupted { return await self?.pause(current) }
                await self?.end(current, reason: Self.interruptedReason, cause: ended ?? "system_interruption")
            }
        }
    }

    /// A host refusal carries its `ErrorCode` before the colon (`HostConnectionFailure.remote("code: message")`).
    static func diagnosticCause(_ error: any Error) -> (cause: String, code: String?) {
        guard case HostConnectionFailure.remote(let message) = error else { return ("send_failed", nil) }
        let code = message.split(separator: ":", maxSplits: 1).first.map(String.init) ?? ""
        let known = DiagnosticField.code.tokens.contains { DiagnosticLimits.sameBytes($0, code) }
        return ("host_refused", known ? code : "other")
    }

    static func describe(_ error: any Error) -> String {
        switch error {
        case HostConnectionFailure.notReady: "the connection changed."
        case HostConnectionFailure.unsupportedCapability: "this host does not accept ambient audio."
        case HostConnectionFailure.remote(let message): "the host ended listening (\(message))."
        case HostConnectionFailure.malformed(let message): "\(message)."
        default: error.localizedDescription
        }
    }
}

/// Scene and binding changes (#282).
extension AmbientListeningController {
    /// Called on every scene or binding change. Streaming starts only in the foreground, for the binding it began
    /// with. A running stream survives the background (#282). A microphone pause also survives a new socket
    /// generation for the same host, target and owner selection; a changed or lost destination ends it.
    public func update(binding current: AmbientAudioBinding?, scene: AmbientScene) async {
        let previous = self.scene
        self.scene = scene
        guard isOn else { return }
        if reconnect.isPending {
            if let current, current.hostID != binding?.hostID || current.targetID != binding?.targetID {
                reconnect.block(.bindingChanged)
            }
            if let current, pausedReason != nil, reconnect.canResumeCapture {
                await updateDestination(current, previous: previous)
            }
            return
        }
        await updateDestination(current, previous: previous)
    }

    private func preservesPause(_ current: AmbientAudioBinding) -> Bool {
        pausedReason != nil && current.hostID == binding?.hostID && current.targetID == binding?.targetID
            && current.selection == binding?.selection
    }

    private func updateDestination(_ current: AmbientAudioBinding?, previous: AmbientScene) async {
        if current != binding {
            guard let current, preservesPause(current) else {
                return await end(session, reason: "Stopped: the destination or connection changed.",
                                 cause: "binding_changed")
            }
            self.binding = current
        }
        switch scene {
        case .active where pausedReason != nil:
            await resume(session, trigger: "foreground")
        case .inactive where pausedReason != nil, .background where pausedReason != nil:
            break
        case .active where pendingStart:
            pendingStart = false
            await start(session)
        case .active:
            break
        case .inactive where awaitingPermission || (pendingStart && previous == .inactive):
            break
        case .inactive where isListening, .background where isListening:
            break
        case .inactive, .background:
            await end(session, reason: "Stopped: Hailing Station left the foreground.", cause: "background")
        }
    }
}

/// Ambient take-over (#366) on the device that took listening over.
extension AmbientListeningController {
    /// The host said this device's stream took listening over from a device of class `from`. While listening to
    /// that host, shows a calm confirmation for `AmbientHandoff.confirmationDuration`, then clears it.
    public func movedHere(from kind: String?, host: HostEndpoint.Identifier) {
        guard isOn, binding?.hostID == host else { return }
        let current = UUID()
        confirmation = current
        handoff = .movedHere(from: kind)
        let sleep = sleep
        Task { [weak self] in
            try? await ambientSleep(for: AmbientHandoff.confirmationDuration, injected: sleep)
            guard let self, self.confirmation == current, case .movedHere? = self.handoff else { return }
            self.handoff = nil
        }
    }
}

/// Recovering from a host-ended stream (#287).
extension AmbientListeningController {
    /// The card went away because the connection or destination did, not because the user turned listening off:
    /// it is reported like any other unexpected stop (#287).
    public func destinationLost() async {
        guard !reconnect.isPending else { return }
        await end(session, reason: "Stopped: the connection or destination went away.", cause: "binding_changed")
    }

    /// Waits before each fresh stream; their count is the cap.
    static let recoveryBackoff: [Duration] = [.seconds(1), .seconds(3), .seconds(10)]
    /// Streaming this long since the last recovery earns a full set of retries again.
    static let recoveryQuietPeriod: Duration = .seconds(120)

    /// True after the backoff when the failure is transient and retries remain: the streamer then opens a new
    /// stream at sequence 0 on the same capture. False lets the failure end listening as before.
    /// Only the live stream recovers: one a pause (#445) replaced, even mid-backoff, never renews.
    func recover(from error: any Error, session current: UUID, streamer: AmbientAudioStreamer?) async -> Bool {
        guard !reconnect.isPending, session == current, isOn,
              Self.isTransient(error), isLive(streamer) else { return false }
        if let lastRecovery, now() - lastRecovery >= Self.recoveryQuietPeriod { recoveries = 0 }
        guard recoveries < Self.recoveryBackoff.count else {
            sendFailure = sendFailure.map { "\($0) Gave up after \(recoveries) restarts." }
            return false
        }
        let sleep = sleep
        let delay = Self.recoveryBackoff[recoveries]
        recoveries += 1
        let wait = Task { try await ambientSleep(for: delay, injected: sleep) }
        recoveryWait = wait
        guard (try? await wait.value) != nil, session == current, isOn, isLive(streamer) else { return false }
        recoveryWait = nil
        lastRecovery = now()
        sendFailure = nil
        sendFailureCause = nil
        diagnostics?.record(.ambientStart)
        return true
    }

    private func isLive(_ candidate: AmbientAudioStreamer?) -> Bool {
        guard let candidate, pausedReason == nil else { return false }
        return candidate === streamer
    }

    /// The host ended our stream but will take a new one: it idled out, its listener exited, or it refused audio
    /// on a stream it had already ended. A busy host, an unselected target or a host without ambient is final.
    static func isTransient(_ error: any Error) -> Bool {
        guard case HostConnectionFailure.remote(let message) = error else { return false }
        return [
            "malformed: ambient stream must be new", "malformed: ambient sequence must increase",
            "not_allowed: ambient stopped:", "rate_limited: ambient rate exceeded"
        ].contains { message.hasPrefix($0) }
    }
}

extension AmbientListeningController {
    /// Ends listening for owner-initiated destination changes.
    public func ownerChangedDestination() async {
        if reconnect.isPending { reconnect.block(.bindingChanged) }
        await destinationLost()
    }
}

/// Another app took the microphone (#445): dictation, a voice memo, a call. Listening pauses instead of turning off,
/// shows why, and resumes when the interruption ends, on returning to the foreground, or on a capped backoff for
/// apps that never say they are done. A resume opens a fresh stream from this same connection, so the host sees no
/// take-over.
extension AmbientListeningController {
    static let pausedStatus = "Paused: another app is using the mic."
    static let foregroundPausedStatus = "Paused: another app is using the mic. Return to the foreground to retry."
    /// Waits between resume attempts; the final delay repeats while listening remains on.
    static let resumeBackoff: [Duration] = [2, 5, 10, 20, 30, 60, 60, 60, 60].map { .seconds($0) }

    func openStreamer(_ current: UUID, binding: AmbientAudioBinding) async throws -> AmbientAudioStreamer {
        let send = send
        let source = StreamerSource()
        source.binding = binding
        let streamer = try await makeStreamer { [weak self] payload in
            do {
                guard let destination = await self?.sendBinding(payload, session: current, source: source) else {
                    throw HostConnectionFailure.notReady
                }
                try await send(payload, destination)
                await self?.transportSent(payload, binding: destination)
            } catch {
                await self?.recordSendFailure(
                    error, session: current, from: source.streamer, streamID: payload.streamID
                )
                throw error
            }
        }
        source.streamer = streamer
        streamer.recovery = { [weak self, weak streamer] error in
            await self?.recover(from: error, session: current, streamer: streamer) ?? false
        }
        return streamer
    }

    /// Reports "listening or paused" once per change (see `onListeningChange`).
    func reportActivity() {
        let active = isListening || pausedReason != nil
        guard active != reportedActivity else { return }
        reportedActivity = active
        onListeningChange?(active)
    }

    func markPaused(_ current: UUID) {
        guard session == current, isOn, pausedReason == nil else { return }
        streamer?.suspendTransport()
        reconnect.capturePaused()
        pausedReason = Self.pausedStatus
        diagnostics?.record(.ambientStop, [.reason: .token("system_interruption")])
    }

    /// The resumer starts before the old stream drains: a backlog held by a slow host must not leave listening
    /// paused with nothing to resume it.
    func pause(_ current: UUID) async {
        markPaused(current)
        guard session == current, isOn, pausedReason != nil, resumer == nil else { return }
        isListening = false
        if let systemEndObserver {
            notificationCenter.removeObserver(systemEndObserver)
            self.systemEndObserver = nil
        }
        resumer = AmbientResumer(
            center: notificationCenter, sleep: sleep, backoff: Self.resumeBackoff,
            attempt: { [weak self] trigger in await self?.resume(current, trigger: trigger) ?? .finished }
        )
        guard let streamer else { return await release(current) }
        self.streamer = nil
        // The outgoing stream must not spend the live stream's recoveries (#287) while it drains, nor finish a
        // recovery it had already begun.
        streamer.recovery = nil
        recoveryWait?.cancel()
        recoveryWait = nil
        await streamer.stop()
        // Released unless a resumed stream or a resume in flight owns the session now. Listening may have ended
        // meanwhile (turned off or moved) with nothing else to release it; `release` checks the owner.
        if self.streamer == nil, resumer?.attempting != true { await release(current) }
    }

    /// Foreground deferrals retain the current retry slot; only a failed microphone start advances it.
    @discardableResult
    func resume(_ current: UUID, trigger: String) async -> AmbientResumer.AttemptResult {
        guard session == current, isOn, pausedReason != nil else { return .finished }
        guard scene == .active else { pausedReason = Self.foregroundPausedStatus; return .deferred }
        guard let resumer, !resumer.attempting, let binding,
              reconnect.prepareCaptureResume(binding) else { return .deferred }
        resumer.attempting = true
        defer { resumer.attempting = false }
        sendFailure = nil
        sendFailureCause = nil
        movedAway = nil
        if await start(current, resuming: true) {
            reconnect.captureResumed()
            resumer.cancel()
            if self.resumer === resumer { self.resumer = nil }
            return .finished
        }
        guard session == current, isOn else { return .finished }
        guard scene == .active else { pausedReason = Self.foregroundPausedStatus; return .deferred }
        diagnostics?.record(.captureError, [.code: .token("resume_failed")])
        return .retry
    }
}

/// One paused session's resume triggers (#445): the session's interruption-ended notification, and a backoff.
@MainActor
final class AmbientResumer {
    enum AttemptResult { case finished, deferred, retry }
    typealias Attempt = @MainActor (String) async -> AttemptResult
    var attempting = false
    private let center: NotificationCenter
    private var token: (any NSObjectProtocol)?
    private var retries: Task<Void, Never>?

    init(
        center: NotificationCenter, sleep: (@Sendable (Duration) async throws -> Void)?,
        backoff: [Duration], attempt: @escaping Attempt
    ) {
        self.center = center
        token = center.addObserver(forName: AudioCaptureEndingSignal.Names.interruption, object: nil, queue: nil) {
            guard AudioCaptureEndingSignal($0) == .interruptionEnded else { return }
            Task { @MainActor in _ = await attempt("interruption_ended") }
        }
        retries = Task { @MainActor in
            guard !backoff.isEmpty else { return }
            var index = 0
            while !Task.isCancelled {
                guard (try? await ambientSleep(for: backoff[index], injected: sleep)) != nil,
                      !Task.isCancelled else { return }
                switch await attempt("retry") {
                case .finished: return
                case .deferred: break
                case .retry: index = min(index + 1, backoff.count - 1)
                }
            }
        }
    }

    func cancel() {
        retries?.cancel()
        retries = nil
        if let token { center.removeObserver(token) }
        token = nil
    }
}

/// The streamer a send closure belongs to, filled in once it exists (#445).
private final class StreamerSource: @unchecked Sendable {
    @MainActor weak var streamer: AmbientAudioStreamer?
    @MainActor var binding: AmbientAudioBinding?
    @MainActor var streamID: UUID?
}

/// The owner's rubber-duck mode (#735) as a host last reported it for this device's ambient stream. State only: the
/// device cannot change the mode, and nothing turns it on yet.
public struct DuckModeStatus: Equatable, Sendable {
    public let on: Bool
    /// Why it last changed: `voice`, `timeout` or `device`, or nil when the host did not say.
    public let reason: String?
    /// When an on mode turns itself off.
    public let expires: Date?

    public init(on: Bool, reason: String? = nil, expires: Date? = nil) {
        self.on = on
        self.reason = reason
        self.expires = on ? expires : nil
    }

    /// From a host's `duck_mode` (Unix milliseconds for `expires`).
    public init(on: Bool, reason: String?, expiresMilliseconds: Int64?) {
        self.init(on: on, reason: reason,
                  expires: expiresMilliseconds.map { Date(timeIntervalSince1970: TimeInterval($0) / 1_000) })
    }

    /// Whether it is on at `now`: an on mode past its expiry counts as off, even before the host says so.
    public func isOn(now: Date = Date()) -> Bool {
        guard on else { return false }
        guard let expires else { return true }
        return expires > now
    }
}

/// Transport restore reuses the live capture and the normal resume wire flag (#904).
extension AmbientListeningController {
    public func turnOff() async {
        reconnect.block(.ownerStop)
        await end(session, reason: nil, cause: "user")
    }

    func ownsAudio(_ streamID: UUID?, binding: AmbientAudioBinding) -> Bool {
        isOn && self.binding == binding && streamID != nil && streamer?.streamID == streamID
    }
    private func sendBinding(_ audio: AudioPayload, session current: UUID,
                             source: StreamerSource) -> AmbientAudioBinding? {
        guard AmbientSendAdmission.isCurrent, source.streamer?.streamID == audio.streamID else { return nil }
        if source.streamID != audio.streamID {
            // A new encoder alone may bind a new generation, and it must open with resume after a restore.
            guard source.streamID == nil || (audio.sequence == 0 && audio.isResume) else { return nil }
            if session == current, streamer === source.streamer, let binding {
                guard source.binding == binding || audio.isResume else { return nil }
                source.binding = binding
            }
            source.streamID = audio.streamID
        }
        // Normal teardown still sends its final tail on the last binding; the store rejects any retired binding.
        return source.binding
    }

    func receiveAmbientRefusal(_ error: any Error, host: HostEndpoint.Identifier,
                               generation: UUID?, streamID: UUID?) {
        guard isOn, binding?.hostID == host, binding?.connectionGeneration == generation,
              let streamer, streamer.streamID == streamID, !Self.isTransient(error) else { return }
        recordSendFailure(error, session: session, from: streamer, streamID: streamID)
        streamer.discardCapture()
        let current = session
        Task { await end(current, reason: sendFailure, cause: "host_refused") }
    }

    private func transportSent(_ audio: AudioPayload, binding: AmbientAudioBinding) {
        if sendFailure == nil, isOn, self.binding == binding, streamer?.streamID == audio.streamID {
            reconnect.sent(audio)
        }
    }
    func suspendTransport() { streamer?.suspendTransport() }
    func retryPausedCapture() {
        let current = session
        Task { [weak self] in _ = await self?.resume(current, trigger: "transport_ready") }
    }
    func restoreTransport(_ binding: AmbientAudioBinding) -> Bool {
        guard isOn else { return false }
        if pausedReason != nil {
            self.binding = binding
            retryPausedCapture()
            return true
        }
        guard isListening, let streamer, streamer.isStreaming else { return false }
        self.binding = binding
        sendFailure = nil
        sendFailureCause = nil
        streamer.resumeTransport()
        return true
    }
    func cancelTransportRestore(reason: AmbientListeningReconnect.Reason? = nil) {
        streamer?.discardCapture()
        isListening = false
        let current = session
        let message = reason == .callAddressChanged
            ? "listening stopped: host address changed during call" : nil
        Task { await end(current, reason: message, cause: "binding_changed") }
    }
    static func isTransportError(_ error: any Error) -> Bool {
        !(error is HostConnectionFailure) || (error as? HostConnectionFailure) == .notReady
    }
}

/// A bounded observable event: equal endpoint/reply/segment values still have distinct ids.
public struct ReplySegmentYieldEvent: Identifiable, Equatable, Sendable {
    public let id: UInt64
    public let endpointID: HostEndpoint.Identifier
    public let replyID: UUID
    public let segment: Int
}

extension HostConnectionStore {
    func publishSegmentYield(_ yield: ReplySegmentPause) {
        segmentYieldEvent = ReplySegmentYieldEvent(
            id: (segmentYieldEvent?.id ?? 0) + 1, endpointID: yield.endpointID,
            replyID: yield.replyID, segment: yield.segment
        )
    }

    /// Install once before capture starts. Authorization is read on main for buffers/onsets in an open pause window.
    public func wireReplySegments(
        playback: ReplyPlaybackController, echoGuard: AmbientReplyEchoGuard,
        authorization: @escaping @MainActor (HostEndpoint.Identifier) -> (ambientListening: Bool, privacyOn: Bool)
    ) {
        guard segmentWiring == nil else { return }
        segmentWiring = ReplySegmentDeviceWiring(store: self, playback: playback, echoGuard: echoGuard,
                                                authorization: authorization)
    }

    /// The owned endpoint only. Failure never undoes the device's local stop.
    @discardableResult
    func sendReplyYield(_ yield: ReplySegmentPause, connectionGeneration: UUID) async -> Bool {
        guard let snapshot = snapshots[yield.endpointID], snapshot.state == .ready,
              snapshot.connectionGeneration == connectionGeneration,
              snapshot.capabilities.contains(ReplySegments.capability),
              let connection = connections[yield.endpointID] else { return false }
        do {
            try await connection.sendReplyYield(yield, connectionGeneration: connectionGeneration)
            return true
        } catch { return false }
    }
}

/// Main-actor bridge for the synchronous pre-mask tap. No PCM crosses this bridge or survives analysis.
/// Installation is once, before capture: it never synchronously stops/reconfigures the tap from a callback.
@MainActor
final class ReplySegmentDeviceWiring {
    private weak var store: HostConnectionStore?
    private let playback: ReplyPlaybackController
    private let echoGuard: AmbientReplyEchoGuard
    private let authorization: @MainActor (HostEndpoint.Identifier) -> (ambientListening: Bool, privacyOn: Bool)
    private var window: Range<ContinuousClock.Instant>?
    private var pause: ReplySegmentPause?
    private var generation: UUID?
    private var replyConnections: [ReplyStreamKey: (generation: UUID, scope: ReplySegmentAdmissionScope)] = [:]
    private var admissionScopes: [HostEndpoint.Identifier: (generation: UUID, scope: ReplySegmentAdmissionScope)] = [:]
    private let inactiveScope = ReplySegmentAdmissionScope()
    private var receivedReplies: [ReplyStreamKey] = []
    private var yielding = false
    /// Whether the last successful yield ended the reply-echo tail early; test observability only.
    private(set) var lastTailRelease: SegmentTailRelease = .notAttempted

    init(
        store: HostConnectionStore, playback: ReplyPlaybackController, echoGuard: AmbientReplyEchoGuard,
        authorization: @escaping @MainActor (HostEndpoint.Identifier) -> (ambientListening: Bool, privacyOn: Bool)
    ) {
        self.store = store
        self.playback = playback
        self.echoGuard = echoGuard
        self.authorization = authorization
        echoGuard.configureSegmentOnset(input: { [weak self] in
            Self.onMain { self?.captureInput() ?? .init(scope: ReplySegmentAdmissionScope(), window: nil,
                                                ambientListening: false, privacyOn: true) }
        }, onOnset: { [weak self] in
            Self.onMain { self?.onset() }
        })
        trackWindow()
    }

    // The capture forwarder is a detached task, never the real-time audio render callback.
    // It hops to main for input only while a pause window is open.
    // Input is called outside the tap lock; onset holds it, so onset must never configure or stop the tap.
    nonisolated private static func onMain<T: Sendable>(_ body: @MainActor @Sendable () -> T) -> T {
        if Thread.isMainThread { return MainActor.assumeIsolated(body) }
        return DispatchQueue.main.sync { MainActor.assumeIsolated(body) }
    }

    private func trackWindow() {
        pause = withObservationTracking { playback.segmentPause } onChange: { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                // Observation fires before mutation. Keep the analysed window until tail release on yield.
                if !self.yielding { self.closeWindow() }
                Task { @MainActor [weak self] in self?.trackWindow() }
            }
        }
        guard let pause else { return closeWindow() }
        let start = playback.idleNow()
        window = start..<start.advanced(by: .seconds(playback.segmentSettings.pauseAfterSegment))
        echoGuard.segmentOnsetGate.openWindow()
        generation = replyConnections[ReplyStreamKey(endpointID: pause.endpointID, replyID: pause.replyID)]?.generation
    }

    /// Bind before playback sees ingress. Later windows, frames and reconnects cannot rebind a known reply.
    /// Keep queued/playing ownership through history eviction; an unbound replay fails closed.
    func receive(_ event: HostReplyEvent) {
        guard let reply = playback.descriptor(in: event.frame),
              let snapshot = store?.snapshots[event.endpointID], snapshot.state == .ready else { return }
        let key = ReplyStreamKey(endpointID: event.endpointID, replyID: reply.id)
        guard replyConnections[key] == nil else { return }
        if receivedReplies.count == HostConnectionStore.replyFrameLimit {
            guard let index = receivedReplies.firstIndex(where: {
                playback.streams[$0] == nil && playback.activeKey != $0
            }) else { return }
            replyConnections.removeValue(forKey: receivedReplies.remove(at: index))
        }
        replyConnections[key] = (snapshot.connectionGeneration,
                                 admissionScope(for: event.endpointID, generation: snapshot.connectionGeneration))
        receivedReplies.append(key)
    }

    private func closeWindow() {
        window = nil
        echoGuard.segmentOnsetGate.closeWindow()
    }

    func captureInput() -> ReplySegmentOnsetInput {
        guard let pause, playback.segmentPause == pause else {
            return .init(scope: inactiveScope, window: nil, ambientListening: false, privacyOn: true)
        }
        let flags = authorization(pause.endpointID)
        let key = ReplyStreamKey(endpointID: pause.endpointID, replyID: pause.replyID)
        return .init(scope: replyConnections[key]?.scope ?? inactiveScope, window: window,
                     ambientListening: flags.ambientListening, privacyOn: flags.privacyOn,
                     settings: playback.segmentSettings)
    }

    func onset() {
        guard let pause, playback.segmentPause == pause, let window,
              window.contains(playback.idleNow()) else { return }
        let flags = authorization(pause.endpointID) // Fresh again at the signal, never captured at window open.
        yielding = true
        defer { yielding = false }
        guard let result = playback.yieldPausedReply(
            ambientListening: flags.ambientListening, privacyOn: flags.privacyOn
        ) else { return }
        // A queued replacement may already be audible. Preserve its mask; otherwise start the ordinary tail.
        echoGuard.setReplyAudible(playback.isReplyAudioOutputBusy)
        // Before close; a refusal preserves the normal tail.
        lastTailRelease = echoGuard.endReplyTailForYield() ? .released : .kept
        closeWindow()
        store?.publishSegmentYield(result)
        guard let generation, let store else { return }
        Task { await store.sendReplyYield(result, connectionGeneration: generation) }
    }

    func ambientRequestAdmitted(from endpoint: HostEndpoint.Identifier) {
        guard let snapshot = store?.snapshots[endpoint], snapshot.state == .ready else { return }
        let scope = admissionScope(for: endpoint, generation: snapshot.connectionGeneration)
        echoGuard.segmentOnsetGate.ambientRequestAdmitted(in: scope)
    }

    private func admissionScope(for endpoint: HostEndpoint.Identifier, generation: UUID) -> ReplySegmentAdmissionScope {
        if let existing = admissionScopes[endpoint], existing.generation == generation { return existing.scope }
        let scope = ReplySegmentAdmissionScope()
        admissionScopes[endpoint] = (generation, scope)
        return scope
    }
}

/// What the last segment yield did to the reply-echo tail (#932).
enum SegmentTailRelease: Equatable, Sendable {
    case notAttempted, released, kept
}

// The restore's acceptance proof: the existing confirmed round trip, with a nonce the store can check in receipt
// order, so a refusal that follows the pong is not misread as a refusal of the unaccepted stream.
extension HostConnection {
    /// A failed selection send can leave receive open; restart only that still-current socket's loop.
    func retryAmbientTransport(generation failed: UUID) async -> Bool {
        guard !Task.isCancelled, wantsConnection, snapshot.connectionGeneration == failed,
              snapshot.state == .ready, socket != nil else { return false }
        await replaceLoop(reconnectAttempt: 1)
        return true
    }

    func confirmRoundTrip(for proof: AmbientResumeAcceptance) async throws {
        guard snapshot.connectionGeneration == proof.binding.connectionGeneration,
              ambientStream?.id == proof.streamID else { throw HostConnectionFailure.notReady }
        let token = generation
        proof.register(token)
        do {
            try await confirmRoundTrip(generation: token, nonce: proof.nonce)
        } catch {
            proof.register(nil)
            throw error
        }
    }

    func hasConfirmed(_ proof: AmbientResumeAcceptance) -> Bool {
        guard let token = proof.token else { return false }
        return hasPong(nonce: proof.nonce, generation: token)
            && snapshot.connectionGeneration == proof.binding.connectionGeneration
    }
}
