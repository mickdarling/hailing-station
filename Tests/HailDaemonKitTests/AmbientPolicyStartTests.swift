import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

private struct PolicyRestartSink: AmbientAudioSink {
    let stream: UUID
    let waiting: PolicyWriteGate
    let recording: RecordingAmbientSink

    func ambientAudio(_ event: AmbientAudioEvent) {
        recording.ambientAudio(event)
        if case .started(let id, _, _) = event, id == stream { waiting.suspend() }
    }
}

@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientPolicyStartTests {
    @Test(arguments: [Tier.open, Tier.confirm, Tier.locked])
    func allowedTierStartsAndStreamsWithoutAWrite(_ tier: Tier) async throws {
        let rig = try await AmbientPolicyRig.make(tier: tier)
        let result: HostSessionResult = await rig.segment(1)
        let active: UUID? = await rig.gate.activeStream
        #expect(result.frames.isEmpty)
        #expect(result.disposition == .keepOpen)
        #expect(rig.sink.segments == [0, 1])
        #expect(rig.sink.endings.isEmpty)
        #expect(active == rig.stream)
    }

    @Test(arguments: [false, true])
    func neverGrantedStartDoesNotClaimPolicyChanged(_ unreadable: Bool) async throws {
        let store = InMemoryPolicyStore()
        let host = try HailHost(registry: Registry(), store: store)
        if unreadable {
            store.setLoadError(PolicyFileError.unwritable("synthetic"))
            let policy: Policy? = await host.refreshedPolicy()
            #expect(policy == nil)
        }
        let sink = RecordingAmbientSink()
        let gate = ambientGate(sink: sink, clock: AmbientTestClock())
        let generation = host.targetPolicy.snapshot(for: "tmux:a")
        let result: AmbientAdmission = await gate.admission(
            ambientSegment(stream: UUID(), sequence: 0), frameTarget: "tmux:a",
            selection: AmbientSelection(target: "tmux:a"), connection: UUID(), device: nil,
            policyGeneration: generation
        )
        let message = "ambient target is not allowed — run haild targets allow on the Mac"
        #expect(result == .refused(.notAllowed, message))
        #expect(sink.events.isEmpty)
    }

    @Test func rewrittenTargetDoesNotMakeNewStartFailureTerminal() async throws {
        let rig = try await AmbientPolicyRig.make()
        let stream = UUID()
        let waiting = PolicyWriteGate()
        defer { waiting.fire() }
        let recording = RecordingAmbientSink()
        let sink = PolicyRestartSink(stream: stream, waiting: waiting, recording: recording)
        let gate = AmbientAudioGate(target: "tmux:a", sink: sink, sweepInterval: nil)
        let session = HostSession(host: rig.host, authorizer: PersonalTerminalAuthorizer(ambientAudio: gate))
        _ = await session.receive(helloFrame())
        _ = await session.receive(sessionFrame(payload: .control(.select(targetID: "tmux:a"))))
        let previous: AudioPayload = ambientSegment(stream: UUID(), sequence: 0, isFinal: true)
        _ = await session.receive(sessionFrame(target: "tmux:a", payload: .audio(previous)))
        _ = try await rig.host.allow("tmux:a", tier: .open)
        let audio: AudioPayload = ambientSegment(stream: stream, sequence: 0)
        let receiving = Task(executorPreference: waiting.executor) {
            await session.receive(sessionFrame(target: "tmux:a", payload: .audio(audio)))
        }
        try await waiting.waitUntilSuspended()
        // A synchronous child startup refusal arrives before the session's admission await returns.
        let frame: Frame? = await session.ambientFailureFrame("ambient stopped: synthetic startup")
        let expected: FramePayload = .control(.error(code: .notAllowed, message: "ambient stopped: synthetic startup"))
        #expect(frame?.payload == expected)
        waiting.fire()
        let result: HostSessionResult = await receiving.value
        #expect(result.frames.isEmpty)
        await gate.end(connection: session.connectionID)
    }

    @Test(arguments: [false, true])
    func unreadableAuthorizedTextKeepsHostPolicyUnavailable(_ alreadyUnreadable: Bool) async throws {
        let rig = try await AmbientPolicyRig.make()
        rig.store.setLoadError(PolicyFileError.unwritable("synthetic"))
        if alreadyUnreadable { _ = await rig.host.refreshedPolicy() }
        let generation = rig.host.targetPolicy.snapshot(for: "tmux:a")
        let expected: HostError = .policyUnavailable("unwritable(\"synthetic\")")
        await #expect(throws: expected) {
            try await rig.host.sendAuthorized("synthetic", policyGeneration: generation, from: "test",
                                              expectedBinding: nil, context: nil)
        }
        let frame: Frame = sessionFrame(target: "tmux:a", payload: .text(TextPayload(text: "synthetic")))
        let result: HostSessionResult = await rig.session.receive(frame)
        let control: ControlPayload = try onlyControl(result)
        // Main maps HostError.policyUnavailable to this phone wire response; it has no policy_unavailable code.
        #expect(control == .error(code: .notAllowed, message: "target action was refused"))
        let deliveries: [FakeAdapter.Delivery] = await rig.adapter.deliveries
        #expect(deliveries.isEmpty)
    }
}
