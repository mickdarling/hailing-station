#if STATION_UI_FIXTURES
import Foundation
import HailCore
import HailProtocol

extension StationScreenSeed {
    @MainActor static var requested: Self? {
        #if os(macOS) || targetEnvironment(simulator)
        #if os(macOS)
        guard Bundle.main.bundleIdentifier == "com.mickdarling.Hail-macOS-shell-tests" else { return nil }
        #endif
        return Self(arguments: ProcessInfo.processInfo.arguments,
                    shellEnabled: StationRedesignLaunch.flags.isOn(.shell))
        #else
        return nil
        #endif
    }

    @MainActor func resources() -> StationResources {
        StationResources(connections: HostConnectionStore(connector: StationSeedConnector()))
    }

    @MainActor func prepare(_ store: HostConnectionStore) async {
        guard let url = URL(string: "ws://station.invalid"),
              let endpoint = try? HostEndpoint(id: StationUITestSeed.hostID, name: "Studio Mac", url: url) else {
            return
        }
        await store.upsert(endpoint)
        if self != .offline { await store.connect(endpoint.id) }
    }

    @MainActor func finishThread(in store: HostConnectionStore, playback: ReplyPlaybackController) {
        let host = StationUITestSeed.hostID
        let target = StationUITestSeed.targetID
        switch self {
        case .refused:
            let frame = Frame(timestamp: 1, target: target, source: target,
                              payload: .control(.error(code: .voiceRouteRefused,
                                                       message: "The session refused the request.", turn: nil)))
            store.ingestForUITesting(HostReplyEvent(endpointID: host, frame: frame))
        case .held:
            let reply = ReplyDescriptor(id: UUID(), hostID: host, targetID: target)
            let frame = Frame(timestamp: 1, target: target, source: target,
                              payload: .text(TextPayload(text: "The reply text is available.", isFinal: true,
                                                         reply: reply)))
            let event = HostReplyEvent(endpointID: host, frame: frame)
            store.ingestForUITesting(event)
            playback.ingest(event)
            playback.togglePause()
        case .ready, .offline: break
        }
    }
}

private struct StationSeedConnector: WebSocketConnecting {
    func open(url: URL, subprotocol: String) async throws -> any WebSocketTransport {
        guard url.host() == "station.invalid" else { throw HostConnectionFailure.notReady }
        return StationSeedSocket()
    }
}

/// No network, microphone or application-input implementation. Only the selection handshake is supported.
private actor StationSeedSocket: WebSocketTransport {
    private var frames: [Data] = []
    private var waiting: CheckedContinuation<Data, any Error>?
    private var closed = false

    func send(_ data: Data) throws {
        guard !closed, case .control(let control) = try FrameCoding.decode(data).payload else {
            throw HostConnectionFailure.notReady
        }
        let response: ControlPayload
        switch control {
        case .hello:
            response = .hello(HelloInfo(versions: VersionNegotiation.supported,
                                        capabilities: ["select_target", PastedText.capability],
                                        deviceName: "Studio Mac"))
        case .listTargets:
            response = .targets([TargetInfo(id: "tmux:ui-test-seed", kind: "tmux", name: "Workbench", alive: true)])
        case .ping(let nonce): response = .pong(nonce: nonce)
        case .select(let target) where target == "tmux:ui-test-seed": return
        default: throw HostConnectionFailure.notReady
        }
        let frame = try FrameCoding.encode(Frame(timestamp: 1, source: "fixture", payload: .control(response)))
        if let waiting {
            self.waiting = nil
            waiting.resume(returning: frame)
        } else {
            frames.append(frame)
        }
    }

    func receive() async throws -> Data {
        guard !closed else { throw HostConnectionFailure.notReady }
        if !frames.isEmpty { return frames.removeFirst() }
        return try await withCheckedThrowingContinuation { waiting = $0 }
    }

    func close() {
        closed = true
        waiting?.resume(throwing: CancellationError())
        waiting = nil
        frames.removeAll()
    }
}
#endif
