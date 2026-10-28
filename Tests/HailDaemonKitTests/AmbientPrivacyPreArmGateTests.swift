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
    /// any off take the switch's path; an on after the connection's stream ended is refused (Jarvis), a stream opened
    /// by `resume` included. A refused start opens nothing. An on after the gate ended the connection is refused as
    /// `ended` (#967 second key), never a pre-arm.
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
        let resumed = UUID()
        var resume = ambientSegment(stream: UUID(), sequence: 0, isFinal: true)
        resume.isResume = true
        #expect(await gate.admit(resume, connection: resumed) == nil)
        await gate.setPrivacy(true, connection: resumed)
        await gate.end(connection: holder)
        await gate.setPrivacy(true, connection: holder)
        #expect(sink.calls.withLock { $0 } == ["prearm \(holder)", "switch true \(holder)", "prearm \(fresh)",
                                               "switch false \(holder)", "refused ended \(holder)"])
    }

    /// #967 P3-1: the ended-connection ring shares the stream bound and evicts oldest first.
    @Test func endedConnectionRingEvictsOldestAtBound() async {
        let sink = PreArmSink()
        let gate = AmbientAudioGate(target: "tmux:a", sink: sink, sweepInterval: nil, endedStreamCapacity: 2)
        let (oldest, middle, newest) = (UUID(), UUID(), UUID())
        for connection in [oldest, middle, newest] { await gate.end(connection: connection) }
        for connection in [oldest, middle, newest] { await gate.setPrivacy(true, connection: connection) }
        #expect(sink.calls.withLock { $0 } == ["prearm \(oldest)", "refused ended \(middle)",
                                               "refused ended \(newest)"])
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

    /// The router refuses a connection that already started a stream, and any once it is stopping, each logged as a
    /// token; a connection already private keeps its arming and logs nothing. Privacy held by another live connection
    /// is taken as a restore takes it, with that connection as its source. (A torn-down connection is refused at the
    /// gate, through the real teardown: `AmbientPrivacyPreArmTeardownTests`.)
    @Test func theRouterRefusesAStreamedOrStoppingConnection() async throws {
        let rig = try await RestoreRig(phrase: nil)
        defer { rig.close() }
        let router = rig.router
        let (_, fresh) = try await rig.connect(capabilities: [DuckMode.capability])
        let (streamed, held, token) = (UUID(), UUID(), UUID())
        router.state.withLock { state in
            state.latest[streamed] = UUID()
            state.duck[held] = AmbientDuckTimer(token: token, timer: nil)
        }
        for connection in [streamed, held, fresh] { router.ambientPrivacyPreArm(connection: connection) }
        #expect(!router.duckMode(connection: streamed))
        #expect(router.duckArming(connection: held) == token && router.duckMode(connection: fresh))
        #expect(router.state.withLock { $0.privacySources[fresh]?.connection } == held)
        #expect(rig.details("ambient_privacy_prearmed") == ["refused=streamed", "source=live"])
        await rig.finish()
        let late = UUID()
        router.ambientPrivacyPreArm(connection: late)
        #expect(!router.duckMode(connection: late))
        #expect(rig.details("ambient_privacy_prearmed").last == "refused=stopping")
    }

    /// The router's own backstop behind the gate's: a connection with a child but no `latest` entry (as after a
    /// take-over, which the gate already refuses) is refused as streamed, and its child is left as it was.
    @Test func theRouterRefusesAConnectionWithAChild() async throws {
        let rig = try await RestoreRig(phrase: nil)
        defer { rig.close() }
        let (_, connection) = try await rig.start()
        let router = rig.router
        router.state.withLock { $0.latest[connection] = nil }
        router.ambientPrivacyPreArm(connection: connection)
        #expect(!router.duckMode(connection: connection))
        #expect(rig.details("ambient_privacy_prearmed") == ["refused=streamed"])
        await rig.finish()
    }

    /// A park overflow alone (#961) is privacy held elsewhere: the pre-arm takes it as a restore does, from no
    /// connection (`from=overflow`), and claims nothing heard.
    @Test func anOverflowAlonePreArmsAsARestore() async throws {
        let rig = try await RestoreRig(phrase: nil)
        defer { rig.close() }
        let router = rig.router
        let (_, connection) = try await rig.connect(capabilities: [DuckMode.capability])
        router.state.withLock { $0.parkOverflow = true }
        router.ambientPrivacyPreArm(connection: connection)
        #expect(router.duckMode(connection: connection) && !router.privacyHeardOn(connection: connection))
        #expect(rig.details("ambient_privacy_prearmed") == ["source=park"])
        #expect(await eventually { rig.details("ambient_privacy_restored").first?.contains("from=overflow") == true },
                "restored from the overflow marker")
        await rig.finish()
    }
}

/// Records each privacy switch and pre-arm the gate hands on.
private final class PreArmSink: AmbientAudioSink {
    let calls = Mutex<[String]>([])
    func ambientAudio(_ event: AmbientAudioEvent) {}
    func ambientPrivacy(_ on: Bool, connection: UUID) { calls.withLock { $0.append("switch \(on) \(connection)") } }
    func ambientPrivacyPreArm(connection: UUID) { calls.withLock { $0.append("prearm \(connection)") } }
    func ambientPrivacyPreArmRefused(connection: UUID, reason: String) {
        calls.withLock { $0.append("refused \(reason) \(connection)") }
    }
}
#endif
