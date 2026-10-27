#if os(macOS)
import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

/// #904: who may pre-arm privacy. The gate hands a pre-arm on only for a connection that has opened no stream (R1),
/// only a ready session whose authorizer admits the privacy switch reaches the gate, and the router refuses a
/// connection that is torn down, already streaming or past shutdown. Synthetic ids only.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget)
struct AmbientPrivacyPreArmGateTests {
    /// R1: a pre-arm for a connection before its first stream, whoever else is listening; the stream holder's on and
    /// any off take the switch's path; an on after the connection's stream ended is refused (Jarvis). A refused start
    /// opens nothing, and a connection's end forgets it.
    @Test func theGateHandsAPreArmOnlyBeforeAConnectionsFirstStream() async {
        let sink = PreArmSink(), (holder, fresh) = (UUID(), UUID())
        let gate = AmbientAudioGate(target: "tmux:a", sink: sink, sweepInterval: nil)
        #expect(await gate.admit(ambientSegment(stream: UUID(), sequence: 1), connection: holder) == .malformed)
        await gate.setPrivacy(true, connection: holder)
        let stream = UUID()
        #expect(await gate.admit(ambientSegment(stream: stream, sequence: 0), connection: holder) == nil)
        await gate.setPrivacy(true, connection: holder)
        await gate.setPrivacy(true, connection: fresh)
        #expect(await gate.admit(ambientSegment(stream: stream, sequence: 1, isFinal: true), connection: holder) == nil)
        #expect(await gate.activeStream == nil)
        await gate.setPrivacy(true, connection: holder)
        await gate.setPrivacy(false, connection: holder)
        await gate.end(connection: holder)
        await gate.setPrivacy(true, connection: holder)
        #expect(sink.calls.withLock { $0 } == ["prearm \(holder)", "switch true \(holder)", "prearm \(fresh)",
                                               "switch false \(holder)", "prearm \(holder)"])
    }

    /// Not ready: a `set_privacy` before the hello closes the session and reaches nothing. Not authorized: a session
    /// whose authorizer has no ambient gate (the probe, or personal mode without ambient) refuses it. A ready session
    /// on the gate's authorizer reaches the pre-arm, for its own connection only.
    @Test func onlyAReadyAuthorizedSessionPreArms() async throws {
        let sink = PreArmSink()
        let gate = AmbientAudioGate(target: "tmux:a", sink: sink, sweepInterval: nil)
        let host = try HailHost(registry: Registry(), store: InMemoryPolicyStore(Policy()))
        let on = sessionFrame(payload: .control(.setPrivacy(on: true)))
        let early = HostSession(host: host, authorizer: PersonalTerminalAuthorizer(ambientAudio: gate))
        #expect(await early.receive(on).disposition == .close)
        let refusers: [any HostSessionAuthorizing] = [ConnectionProbeAuthorizer(), PersonalTerminalAuthorizer()]
        for authorizer in refusers {
            let session = HostSession(host: host, authorizer: authorizer)
            _ = await session.receive(helloFrame())
            guard case .error(let code, _, _) = try onlyControl(await session.receive(on)) else {
                Issue.record("expected a refusal")
                continue
            }
            #expect(code == .unauthorized)
        }
        #expect(sink.calls.withLock { $0 }.isEmpty)
        let ready = HostSession(host: host, authorizer: PersonalTerminalAuthorizer(ambientAudio: gate))
        _ = await ready.receive(helloFrame())
        #expect(await ready.receive(on).frames.isEmpty)
        let connection = await ready.connectionID
        #expect(sink.calls.withLock { $0 } == ["prearm \(connection)"])
    }

    /// The router refuses a torn-down connection, one that already started a stream, and any once it is stopping,
    /// each logged as a token; a connection already private keeps its arming and logs nothing. Privacy held by another
    /// live connection is taken as a restore takes it, with that connection as its source.
    @Test func theRouterRefusesAClosedStreamedOrStoppingConnection() async throws {
        let rig = try await RestoreRig(phrase: nil)
        defer { rig.close() }
        let router = rig.router
        let (closed, streamed, held, fresh, token) = (UUID(), UUID(), UUID(), UUID(), UUID())
        router.state.withLock { state in
            state.closed.insert(closed)
            state.latest[streamed] = UUID()
            state.duck[held] = AmbientDuckTimer(token: token, timer: nil)
        }
        for connection in [closed, streamed, held, fresh] { router.ambientPrivacyPreArm(connection: connection) }
        #expect(!router.duckMode(connection: closed) && !router.duckMode(connection: streamed))
        #expect(router.duckArming(connection: held) == token && router.duckMode(connection: fresh))
        #expect(router.state.withLock { $0.privacySources[fresh]?.connection } == held)
        #expect(rig.details("ambient_privacy_prearmed") == ["refused=closed", "refused=streamed", "source=live"])
        await rig.finish()
        let late = UUID()
        router.ambientPrivacyPreArm(connection: late)
        #expect(!router.duckMode(connection: late))
        #expect(rig.details("ambient_privacy_prearmed").last == "refused=stopping")
    }
}

/// Records each privacy switch and pre-arm the gate hands on.
private final class PreArmSink: AmbientAudioSink {
    let calls = Mutex<[String]>([])
    func ambientAudio(_ event: AmbientAudioEvent) {}
    func ambientPrivacy(_ on: Bool, connection: UUID) { calls.withLock { $0.append("switch \(on) \(connection)") } }
    func ambientPrivacyPreArm(connection: UUID) { calls.withLock { $0.append("prearm \(connection)") } }
}
#endif
