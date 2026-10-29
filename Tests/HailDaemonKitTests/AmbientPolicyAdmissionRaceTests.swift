import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

private struct PolicyInspectingSink: AmbientAudioSink {
    let authority: TargetPolicyAuthority
    let recording: RecordingAmbientSink

    func ambientAudio(_ event: AmbientAudioEvent) {
        // Synchronous reentry takes the same lock, including on .started; no spawn-length lock is held.
        _ = authority.snapshot(for: "tmux:a")
        recording.ambientAudio(event)
    }
}

private struct PolicyBlockingSink: AmbientAudioSink {
    let started: PolicyWriteGate
    let recording: RecordingAmbientSink
    var blocksSegment = false

    func ambientAudio(_ event: AmbientAudioEvent) {
        recording.ambientAudio(event)
        if case .started = event, !blocksSegment { started.suspend() }
        if case .segment = event, blocksSegment { started.suspend() }
    }
}

@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientPolicyAdmissionRaceTests {
    @Test(arguments: [false, true])
    func retirementDuringStartedDropsStagedPCM(_ isFinal: Bool) async throws {
        let rig = try await AmbientPolicyRig.make()
        let started = PolicyWriteGate()
        defer { started.fire() }
        let recording = RecordingAmbientSink()
        let sink = PolicyBlockingSink(started: started, recording: recording)
        let gate = AmbientAudioGate(target: "tmux:a", sink: sink, sweepInterval: nil)
        let session = HostSession(host: rig.host, authorizer: PersonalTerminalAuthorizer(ambientAudio: gate))
        _ = await session.receive(helloFrame())
        _ = await session.receive(sessionFrame(payload: .control(.select(targetID: "tmux:a"))))
        let stream = UUID()
        let audio: AudioPayload = ambientSegment(stream: stream, sequence: 0, isFinal: isFinal)
        let receiving = Task(executorPreference: started.executor) {
            await session.receive(sessionFrame(target: "tmux:a", payload: .audio(audio)))
        }
        try await started.waitUntilSuspended()
        let denied: Bool = try await rig.host.deny("tmux:a")
        let result: HostSessionResult = try await started.finish(receiving)
        #expect(denied)
        #expect(rig.store.stored.targets["tmux:a"] == nil)
        let controls: [FramePayload] = result.frames.map(\.payload)
        let expected: FramePayload = .control(.error(code: .notAllowed, message: "ambient target_policy_changed"))
        let active: UUID? = await gate.activeStream
        #expect(controls == [expected])
        #expect(result.disposition == .keepOpen)
        #expect(recording.segments.isEmpty)
        #expect(recording.endings == [.notAllowed])
        #expect(active == nil)
        let starts: Int = recording.events.filter { if case .started = $0 { true } else { false } }.count
        #expect(starts == 1)
    }

    @Test func retirementDuringSegmentDropsStagedFinal() async throws {
        let rig = try await AmbientPolicyRig.make()
        let blocked = PolicyWriteGate()
        defer { blocked.fire() }
        let recording = RecordingAmbientSink()
        let sink = PolicyBlockingSink(started: blocked, recording: recording, blocksSegment: true)
        let gate = AmbientAudioGate(target: "tmux:a", sink: sink, sweepInterval: nil)
        let session = HostSession(host: rig.host, authorizer: PersonalTerminalAuthorizer(ambientAudio: gate))
        _ = await session.receive(helloFrame())
        _ = await session.receive(sessionFrame(payload: .control(.select(targetID: "tmux:a"))))
        let audio: AudioPayload = ambientSegment(stream: UUID(), sequence: 0, isFinal: true)
        let receiving = Task(executorPreference: blocked.executor) {
            await session.receive(sessionFrame(target: "tmux:a", payload: .audio(audio)))
        }
        try await blocked.waitUntilSuspended()
        _ = try await rig.host.deny("tmux:a")
        let result: HostSessionResult = try await blocked.finish(receiving)
        let controls: [FramePayload] = result.frames.map(\.payload)
        let expected: FramePayload = .control(.error(code: .notAllowed, message: "ambient target_policy_changed"))
        #expect(controls == [expected])
        #expect(recording.segments == [0])
        #expect(recording.endings == [.notAllowed])
    }

    @Test(arguments: ["tmux:a", "tmux:b"], [false, true])
    func admissionDuringSuspendedPersist(_ target: String, _ externalChange: Bool) async throws {
        let persist = PolicyWriteGate()
        defer { persist.fire() }
        let rig = try await AmbientPolicyRig.make(beforeUpdate: { persist.suspend() })
        let writing = Task(executorPreference: persist.executor) { try await rig.host.deny(target) }
        try await persist.waitUntilSuspended()
        // The store has entered update, but its policy has not changed and persistence cannot finish yet.
        let stored: Policy = rig.store.stored
        if externalChange {
            // Force the backstop to reload while the daemon's target is retired but persistence is suspended.
            var changed = stored
            changed.deliveriesPerMinute += 1
            rig.store.overwrite(changed)
        }
        let next: HostSessionResult = await rig.segment(1)
        let active: UUID? = await rig.gate.activeStream
        let changed: Bool = try await persist.finish(writing)
        #expect(stored.targets[target]?.tier == .open)
        if target == "tmux:a" {
            let controls: [FramePayload] = next.frames.map(\.payload)
            let expected: FramePayload = .control(.error(code: .notAllowed, message: "ambient target_policy_changed"))
            #expect(controls == [expected])
            #expect(next.disposition == .keepOpen)
            #expect(rig.sink.segments == [0])
            #expect(rig.sink.endings == [.notAllowed])
            #expect(active == nil)
        } else {
            #expect(next.frames.isEmpty)
            #expect(rig.sink.segments == [0, 1])
            #expect(rig.sink.endings.isEmpty)
            #expect(active == rig.stream)
        }
        #expect(changed)
    }

    @Test func callbacksRunOutsideTheGenerationLock() async throws {
        let rig = try await AmbientPolicyRig.make()
        let recording = RecordingAmbientSink()
        let sink = PolicyInspectingSink(authority: rig.host.targetPolicy, recording: recording)
        let gate = AmbientAudioGate(target: "tmux:a", sink: sink, sweepInterval: nil)
        let stream = UUID()
        let connection = UUID()
        let generation = rig.host.targetPolicy.snapshot(for: "tmux:a")
        let result: AmbientAdmission = await gate.admission(
            ambientSegment(stream: stream, sequence: 0, isFinal: true), frameTarget: "tmux:a",
            selection: AmbientSelection(target: "tmux:a"), connection: connection, device: nil,
            policyGeneration: generation
        )
        let expected: [AmbientAudioEvent] = [
            .started(stream: stream, connection: connection),
            .segment(stream: stream, sequence: 0, bytes: Data(repeating: 0, count: 3_200)),
            .ended(stream: stream, reason: .final)
        ]
        #expect(result == .admitted)
        #expect(recording.events == expected)
    }

    @Test func failedPersistStillRetiresOnlyTheAffectedGrant() async throws {
        var policy = Policy()
        try policy.allow("tmux:a", binding: "binding-a", tier: .open)
        try policy.allow("tmux:b", binding: "binding-b", tier: .open)
        let failure = PolicyFileError.unwritable("synthetic")
        let store = InMemoryPolicyStore(policy, saveError: failure)
        let host = try HailHost(registry: Registry(), store: store)
        let affected = host.targetPolicy.snapshot(for: "tmux:a")
        let unrelated = host.targetPolicy.snapshot(for: "tmux:b")
        await #expect(throws: failure) { try await host.setTier(.confirm, for: "tmux:a") }
        let retired: Bool = affected.performIfCurrent({ true }) == true
        let retained: Bool = unrelated.performIfCurrent({ true }) == true
        #expect(!retired)
        #expect(retained)
        #expect(store.stored == policy)
    }
}
