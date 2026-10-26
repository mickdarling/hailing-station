#if os(macOS)
import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

/// The router's test-only acknowledgement hold (#894), as a value so a trailing `onEvent` closure never binds to it.
struct AcknowledgementHold {
    let wait: @Sendable () async -> Void
}

/// The router's test-only hook just before a "Nothing was sent." clip's frames are sent (#913), as a value like
/// `AcknowledgementHold`.
struct NotSentPlaying {
    let wait: @Sendable (UUID) async -> Void
}

/// Records each connection the router queued a "Nothing was sent." clip for (#894), through its test-only hook.
final class NotSentQueued: Sendable {
    private let queued = Mutex<[UUID]>([])
    func note(_ connection: UUID) { queued.withLock { $0.append(connection) } }
    func count(for connection: UUID) -> Int { queued.withLock { $0.filter { $0 == connection }.count } }
}

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

struct PendingInputOptions {
    var holdFirst = false
    var capabilities = ["probe", RequestRefusals.capability]
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
    let queued: NotSentQueued
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
    var lastInput: LastInputLedger.Entry? {
        get async { await env.listener.lastInput.latest(for: RecipientTestRig.target) }
    }

    /// The enrolled fixture's owner request said as "Deck." (a voice-route refusal, #636), then, once `go2` exists, the
    /// same request under new ids, as said ("Rightyo, archive the project."), typed to the stream's target; the session
    /// stops once stdin closes.
    static let routeThenTarget = #"""
        names='s/"phase": "started"/"addressing": {"names": ["Rightyo"]}, "phase": "started"/'
        /usr/bin/sed -n -e '1,3p' events.jsonl | /usr/bin/sed -e "s/formed-demo/$7/g" -e "$names"
        /usr/bin/sed -n -e '4,6p' events.jsonl | /usr/bin/sed -e 's/Rightyo, archive the project./Deck./g' \
            -e "s/formed-demo/$7/g"
        while [ ! -f go2 ]; do /bin/sleep 0.02; done
        /usr/bin/sed -n -e '4,6p' events.jsonl | /usr/bin/sed -e 's/"sequence": \([4-6]\),/"sequence": 1\1,/' \
            -e 's/formed-demo:request/formed-demo:again/' -e 's/"utterance_id": "request"/"utterance_id": "again"/g' \
            -e "s/formed-demo/$7/g"
        /bin/cat > /dev/null
        /usr/bin/sed -n -e '$p' events.jsonl | /usr/bin/sed -e 's/"sequence": 7,/"sequence": 17,/' \
            -e "s/formed-demo/$7/g"
        """#

    /// `options.holdFirst` keeps the first request back until the test releases `go1`. `hold` is the router's test-only
    /// acknowledgement hold, and `playing` its hook just before a "Nothing was sent." clip is sent (#913); `extra`
    /// adds clip folders to the library.
    static func make(
        options: PendingInputOptions = .init(), script: String = RightyoAmbientPendingInputTests.twoRequests,
        fixture: String = "tool-events.jsonl", routes: VoiceRoutes? = nil, hold: AcknowledgementHold? = nil,
        playing: NotSentPlaying? = nil, extra: [String: [AmbientAckClip]] = [:]
    ) async throws -> Self {
        let fake = try FakeRightyo(script)
        try fake.install(fixture: fixture)
        if !options.holdFirst { try RightyoAmbientPendingInputTests.release(fake, "go1") }
        let (log, queued) = (AmbientEventDetails(), NotSentQueued())
        let library = AmbientAckLibrary(clips: ["default": [ack],
                                                "confirmnotsent": [AmbientVoiceRouteRefusalTests.notSent]]
                                            .merging(extra) { old, _ in old })
        let env = try await ambientRig(fake, timing: .init(eofGrace: 0.5, termGrace: 2), acknowledgements: library,
                                       routes: routes, acknowledgementHold: hold, notSentQueued: queued,
                                       notSentPlaying: playing, onEvent: { log.record($0) })
        let pair = try await FallbackSocketPair.boundedConnect(
            port: env.port, selecting: [RecipientTestRig.target], capabilities: options.capabilities
        )
        return Self(fake: fake, env: env, pair: pair, log: log, queued: queued)
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
