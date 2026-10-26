#if os(macOS)
import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

/// What a device received, as `AmbientWiringInputPendingTests` compares it.
enum PendingInputSeen: Equatable {
    case control(ControlPayload)
    case text(String)
    case audio
}

/// Every event the router logged.
final class AmbientEventDetails: Sendable {
    private let events = Mutex<[WebSocketListenerEvent]>([])
    func record(_ event: WebSocketListenerEvent) { events.withLock { $0.append(event) } }
    func details(_ name: String) -> [String] {
        events.withLock { $0.filter { $0.event == name }.map { $0.detail ?? "" } }
    }
    var allDetails: [String] { events.withLock { $0.compactMap(\.detail) } }
}

/// One device, taking request refusals, streaming to a child that sends two requests (see
/// `RightyoAmbientPendingInputTests.twoRequests`), with a `default` acknowledgement ("On it.") and the
/// `confirm-not-sent/` clip in the library.
struct PendingInputRun {
    static let ack = AmbientAckClip(pcm: Data(repeating: 7, count: 480), sampleRate: 24_000, text: "On it.")
    let fake: FakeRightyo
    let env: AmbientWiringRig
    let pair: FallbackSocketPair
    let log: AmbientEventDetails
    var socket: URLSessionWebSocketTask { pair.sockets[0] }
    var adapter: RecipientContextAdapter { env.rig.adapter }
    /// The device's session connection id, the one the router and the last-input ledger key on (not the peer key
    /// `session_connected` logs).
    var connection: UUID? {
        get async {
            guard let key = env.connected.all.first, let peer = await env.listener.peers[key] else { return nil }
            return await peer.session.connectionID
        }
    }
    /// The stream target's last input device (#370), if any was recorded.
    var lastInput: LastInputLedger.Entry? { env.listener.lastInput.latest(for: RecipientTestRig.target) }

    /// `holdFirst` keeps the first request back until the test releases `go1`.
    static func make(holdFirst: Bool = false) async throws -> Self {
        let fake = try FakeRightyo(RightyoAmbientPendingInputTests.twoRequests)
        try fake.install(fixture: "tool-events.jsonl")
        if !holdFirst { try RightyoAmbientPendingInputTests.release(fake, "go1") }
        let log = AmbientEventDetails()
        let library = AmbientAckLibrary(clips: ["default": [ack],
                                                "confirmnotsent": [AmbientVoiceRouteRefusalTests.notSent]])
        let env = try await ambientRig(fake, timing: .init(eofGrace: 0.5, termGrace: 2), acknowledgements: library,
                                       onEvent: { log.record($0) })
        let pair = try await FallbackSocketPair.boundedConnect(
            port: env.port, selecting: [RecipientTestRig.target], capabilities: ["probe", RequestRefusals.capability]
        )
        return Self(fake: fake, env: env, pair: pair, log: log)
    }

    func speak() async throws { try await recipientSocketSend(audio(UUID(), 0), on: socket) }
    func release(_ name: String) throws { try RightyoAmbientPendingInputTests.release(fake, name) }

    /// The next `count` frames on the device.
    func seen(_ count: Int) async throws -> [PendingInputSeen] {
        var seen: [PendingInputSeen] = []
        while seen.count < count {
            let frame = try await receiveFrame(on: socket, step: "frame \(seen.count)")
            switch frame.payload {
            case .control(let control): seen.append(.control(control))
            case .text(let text): seen.append(.text(text.text))
            case .audio: seen.append(.audio)
            default: seen.append(.text("unexpected \(frame.payload)"))
            }
        }
        return seen
    }

    /// Whether a live session holds `id` as a reply request: a recipient armed for it.
    func armed(_ id: UUID) async -> Bool {
        for peer in await env.listener.peers.values where await peer.session.replyRequests[id] != nil { return true }
        return false
    }

    func finish() async { await env.listener.stop(reason: "synthetic test complete") }

    func close() {
        pair.close()
        fake.cleanUp()
    }
}
#endif
