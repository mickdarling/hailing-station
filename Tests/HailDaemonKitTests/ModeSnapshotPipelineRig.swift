#if os(macOS)
import Foundation
import HailProtocol
import Network
import Synchronization
import Testing
@testable import HailDaemonKit

struct ModeSnapshotPipelineAuthorizer: HostSessionAuthorizing {
    let ambientAudio: AmbientAudioGate?
    let order: ModeSnapshotWireOrder
    let hello: ObservedGate
    var capabilities: [String] { PersonalTerminalAuthorizer(ambientAudio: ambientAudio).capabilities }
    func authorize(_ frame: Frame) async -> HostSessionAuthorization {
        switch frame.payload {
        case .control(.hello): await hello.pause()
        case .control(.select): order.observe("select")
        case .audio: order.observe("audio_frame")
        default: break
        }
        return await PersonalTerminalAuthorizer(ambientAudio: ambientAudio).authorize(frame)
    }
}

struct ModeSnapshotPipelineSink: AmbientAudioSink {
    let order: ModeSnapshotWireOrder
    func ambientAudio(_ event: AmbientAudioEvent) {
        switch event {
        case .started: order.observe("started")
        case .segment: order.observe("pcm")
        case .ended: break
        }
    }
}

/// Real production WebSocketPeer and HostSession on loopback; the hello barrier queues the complete pipeline
/// before any host response.
final class ModeSnapshotPipelineRig: Sendable {
    let order = ModeSnapshotWireOrder()
    let hello = ObservedGate()
    let listener: NWListener
    let session: HostSession
    private let peer = Mutex<WebSocketPeer?>(nil)
    private let ready = Mutex<UInt16?>(nil)
    private let queue = DispatchQueue(label: "hail.tests.mode-snapshot-pipeline")

    init() async throws {
        var policy = Policy()
        try policy.allow("tmux:a", binding: "binding-a", tier: .open)
        let (host, _) = try await sessionHost(targets: [AdapterTarget(name: "a", binding: "binding-a")], policy: policy)
        let audio = AmbientAudioGate(target: "tmux:a", sink: ModeSnapshotPipelineSink(order: order), sweepInterval: nil)
        session = HostSession(host: host, authorizer: ModeSnapshotPipelineAuthorizer(
            ambientAudio: audio, order: order, hello: hello))
        let webSocket = NWProtocolWebSocket.Options(.version13)
        webSocket.setClientRequestHandler(queue) { _, _ in
            .init(status: .accept, subprotocol: WebSocketListener.subprotocolName)
        }
        let framer = NWProtocolFramer.Options(definition: .init(implementation: ModeSnapshotObservingFramer.self))
        framer["order"] = order
        let parameters = NWParameters(tls: nil, tcp: NWProtocolTCP.Options())
        parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: .any)
        parameters.defaultProtocolStack.applicationProtocols = [webSocket, framer]
        listener = try NWListener(using: parameters)
        start()
    }

    private func start() {
        listener.stateUpdateHandler = { [weak self] state in
            if case .ready = state, let self { ready.withLock { $0 = listener.port?.rawValue } }
        }
        listener.newConnectionHandler = { [weak self] connection in
            guard let self else { return connection.cancel() }
            let value = WebSocketPeer(id: UUID(), connection: connection, session: session, queue: queue,
                                      helloTimeout: .seconds(10), log: { _ in }, onEnd: { _ in })
            peer.withLock { $0 = value }
            Task { await value.start() }
        }
        listener.start(queue: queue)
    }

    func connect() async throws -> SilentPeer {
        try #require(await eventually { self.ready.withLock { $0 != nil } }, "pipeline listener ready")
        return try await SilentPeer.connect(port: #require(ready.withLock { $0 }))
    }

    func close() async {
        await hello.releaseAll()
        listener.cancel()
        await peer.withLock { $0 }?.stop(reason: "synthetic pipeline complete")
    }
}
#endif
