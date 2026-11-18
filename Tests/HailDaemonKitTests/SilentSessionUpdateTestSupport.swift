import Foundation
import HailProtocol
import Network
import Synchronization
import Testing
@testable import HailDaemonKit

struct UnusedUpdateSpeech: SessionUpdateSpeechRendering {
    func render(_ text: String, publish: @Sendable (Data, Bool) async throws -> Void) async throws {
        Issue.record("this card-only fixture must not render audio")
    }
}

/// Synthetic transport completions, registry and invented text. No socket or child is started.
struct SilentUpdateRig {
    let host: RecipientTestRig
    let listener: WebSocketListener
    let session: HostSession
    let peer: WebSocketPeer
    let connection: UUID
    let evidence: SilentUpdateEvidence

    static func make(
        ambient: (any AmbientListenerWiring)? = nil, installRecipient: Bool = true
    ) async throws -> Self {
        let host = try await RecipientTestRig.make(), evidence = SilentUpdateEvidence()
        let session = HostSession(host: host.host, authorizer: PersonalTerminalAuthorizer())
        _ = await session.receive(helloFrame(capabilities: [SessionUpdateCard.capability]))
        _ = await session.receive(sessionFrame(payload: .control(.select(targetID: RecipientTestRig.target))))
        let listener = try WebSocketListener(bindAddress: "127.0.0.1", port: 0, host: host.host,
            ambient: ambient, log: { event in evidence.logs.withLock { $0.append(event) } })
        let peer = WebSocketPeer(id: UUID(), connection: NWConnection(host: "127.0.0.1", port: 9, using: .tcp),
            session: session, queue: DispatchQueue(label: "synthetic.silent"), helloTimeout: .seconds(5),
            log: { _ in }, onEnd: { _ in }, submitReply: { complete in
                evidence.sends.withLock { $0 += 1 }; complete(nil)
            })
        await listener.enableSessionUpdates()
        let connection = await session.connectionID, generation = await session.selectionGeneration
        if installRecipient {
            await listener.installSessionUpdateTestPeer(peer, connectionID: connection, generation: generation)
        }
        return Self(host: host, listener: listener, session: session, peer: peer,
                    connection: connection, evidence: evidence)
    }

    func submit(_ priority: SessionUpdatePriority = .info) async -> LocalSessionUpdateReport {
        await listener.sessionUpdate(.init(action: .submit, target: RecipientTestRig.target,
            priority: priority, text: "Synthetic secret card", card: "Synthetic secret metadata"))
    }

    func frame(_ reply: UUID, final: Bool = false, text: Bool = false) -> Frame {
        let descriptor = ReplyDescriptor(id: reply, hostID: "mac-test", targetID: RecipientTestRig.target,
                                         audioStreamID: reply)
        return sessionFrame(target: RecipientTestRig.target, payload: text
            ? .text(TextPayload(text: "Synthetic reply", reply: descriptor))
            : .audio(AudioPayload(codec: .pcm16, sampleRate: 24_000, channels: 1, sequence: final ? 1 : 0,
                streamID: reply, isFinal: final, bytes: Data([0, 0]), reply: descriptor)))
    }

    func send(_ frame: Frame) async throws {
        let prepared = try #require(await peer.prepareReplyPublication(frame))
        #expect(prepared.enqueue())
        #expect(await prepared.result() == .sent)
    }

    var sends: Int { evidence.sends.withLock { $0 } }
    var drains: [String] {
        evidence.logs.withLock { $0.filter { $0.event == "session_update_drained" }.compactMap(\.detail) }
    }
}

final class SilentUpdateEvidence: Sendable {
    let sends = Mutex(0)
    let logs = Mutex<[WebSocketListenerEvent]>([])
}

extension WebSocketListener {
    func setSyntheticQuiet(_ on: Bool) { sessionUpdatesQuiet = on }
}
