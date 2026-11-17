import Foundation
import HailProtocol
import Network
import Synchronization
import Testing
@testable import HailDaemonKit

/// Invented cards and transport completions only. No socket is started and no renderer or provider is launched.
struct SessionUpdateSettleRig {
    let hostRig: RecipientTestRig
    let listener: WebSocketListener
    let session: HostSession
    let peer: WebSocketPeer
    let clock: ProgressTestClock
    let evidence: SettleEvidence
    let connection: UUID

    static func make(ambient: (any AmbientListenerWiring)? = nil) async throws -> Self {
        let host = try await RecipientTestRig.make(), clock = ProgressTestClock()
        let evidence = SettleEvidence()
        let session = HostSession(host: host.host, authorizer: PersonalTerminalAuthorizer(),
                                  requestClock: { clock.now })
        _ = await session.receive(helloFrame(capabilities: [SessionUpdateCard.capability]))
        _ = await session.receive(sessionFrame(payload: .control(.select(targetID: RecipientTestRig.target))))
        let listener = try WebSocketListener(bindAddress: "127.0.0.1", port: 0, host: host.host,
            ambient: ambient, log: { event in evidence.logs.withLock { $0.append(event) } })
        let peer = WebSocketPeer(id: UUID(), connection: NWConnection(host: "127.0.0.1", port: 9, using: .tcp),
            session: session, queue: DispatchQueue(label: "synthetic.settle"), helloTimeout: .seconds(5),
            log: { _ in }, onEnd: { _ in }, submitReply: { complete in
                evidence.sends.withLock { $0 += 1 }; complete(nil)
            })
        await listener.enableSessionUpdates()
        let connection = await session.connectionID, generation = await session.selectionGeneration
        await listener.installSessionUpdateTestPeer(peer, connectionID: connection, generation: generation)
        await listener.installSettleClock(clock.clock, session: session,
                                          didFire: { evidence.fires.withLock { $0 += 1 } })
        return Self(hostRig: host, listener: listener, session: session, peer: peer, clock: clock,
                    evidence: evidence, connection: connection)
    }

    func submit(_ priority: SessionUpdatePriority = .info) async -> LocalSessionUpdateReport {
        let result = await listener.sessionUpdate(.init(action: .submit, target: RecipientTestRig.target,
            priority: priority, text: "Synthetic secret card", card: "Synthetic secret metadata"))
        await listener.refreshSessionUpdateSettles()
        return result
    }

    func refresh() async { await listener.refreshSessionUpdateSettles() }

    func advanceAndFire(_ by: Duration = .seconds(8)) async {
        let before = evidence.fires.withLock { $0 }
        clock.advance(by: by)
        #expect(await eventually { evidence.fires.withLock { $0 } > before }, "scheduled settle callback completed")
    }

    var deliveries: Int { evidence.sends.withLock { $0 } }
    var drains: [WebSocketListenerEvent] {
        evidence.logs.withLock { $0.filter { $0.event == "session_update_drained" } }
    }
}

extension WebSocketListener {
    func installSettleClock(_ clock: TaskProgressClock, session: HostSession,
                            didFire: @escaping @Sendable () -> Void) {
        sessionUpdateSettleDidFire = didFire
        sessionUpdateSettleClock = clock
        observeSessionUpdateActivity(session)
    }

    func settleDue(_ connection: UUID) -> ContinuousClock.Instant? { sessionUpdateSettles[connection]?.due }
    func setSyntheticQuiet(_ on: Bool) { sessionUpdatesQuiet = on }
    func endSettlePeer() async {
        guard let id = peers.keys.first else { return }
        await peerEnded(id)
    }
}

struct SettleConfiguredSpeech: SessionUpdateSpeechRendering {
    func render(_ text: String, publish: @Sendable (Data, Bool) async throws -> Void) async throws {
        Issue.record("silent settle must not launch speech")
    }
}

final class SettleGuardWiring: AmbientListenerWiring {
    private struct State { var media = false, meeting = false, privacy = false }
    private let state = Mutex(State())
    func attach(_ listener: WebSocketListener) {}
    func stop(connection: UUID) {}
    func shutdown() async {}
    func isLatest(stream: UUID, connection: UUID) -> Bool { false }
    func deviceVoiceStopped(connection: UUID, latencyMs: Int?) async {}
    var sessionUpdatesPrivate: Bool { state.withLock { $0.privacy } }
    func mediaMode(connection: UUID) -> Bool { state.withLock { $0.media } }
    func withSessionUpdatePermission(connection: UUID, enqueue: @Sendable () -> Bool) -> Bool {
        state.withLock { !$0.media && !$0.meeting && !$0.privacy && enqueue() }
    }
    func set(_ mode: String, on: Bool) {
        state.withLock {
            switch mode {
            case "media": $0.media = on
            case "meeting": $0.meeting = on
            default: $0.privacy = on
            }
        }
    }
}

final class SettleEvidence: Sendable {
    let sends = Mutex(0), fires = Mutex(0)
    let logs = Mutex<[WebSocketListenerEvent]>([])
}
