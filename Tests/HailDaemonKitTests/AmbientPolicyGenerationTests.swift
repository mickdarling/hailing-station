import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

@Suite(.frozenGuardBudget) struct AmbientPolicyGenerationTests {
    @Test(arguments: [false, true])
    func lateChildFailureKeepsPolicyStopTerminal(_ externally: Bool) async throws {
        let rig = try await AmbientPolicyRig.make()
        try await rig.write(.deny, target: "tmux:a", externally: externally)
        _ = await rig.segment(1)
        let frame: Frame? = await rig.session.ambientFailureFrame("ambient stopped: synthetic")
        let expected: FramePayload = .control(.error(code: .notAllowed, message: "ambient target_policy_changed"))
        #expect(frame?.payload == expected)
    }

    @Test func otherTargetWriteKeepsOrdinaryChildRecovery() async throws {
        let rig = try await AmbientPolicyRig.make()
        try await rig.write(.deny, target: "tmux:b", externally: false)
        let frame: Frame? = await rig.session.ambientFailureFrame("ambient stopped: synthetic")
        let expected: FramePayload = .control(.error(code: .notAllowed, message: "ambient stopped: synthetic"))
        #expect(frame?.payload == expected)
    }

    @Test(arguments: [Tier.confirm, Tier.locked])
    func ineligibleTierCannotStartANewStream(_ tier: Tier) async throws {
        let rig = try await AmbientPolicyRig.make()
        _ = try await rig.host.setTier(tier, for: "tmux:a")
        let audio: AudioPayload = ambientSegment(stream: UUID(), sequence: 0)
        let result: HostSessionResult = await rig.session.receive(
            sessionFrame(target: "tmux:a", payload: .audio(audio))
        )
        let control: ControlPayload = try onlyControl(result)
        #expect(control == .error(code: .notAllowed, message: "ambient target_policy_changed"))
        #expect(rig.sink.segments == [0])
        #expect(rig.sink.endings == [.notAllowed])
    }

    @Test func staleStartSnapshotIsRefusedAtSinkAdmission() async throws {
        let rig = try await AmbientPolicyRig.make()
        let snapshot = rig.host.targetPolicy.snapshot(for: "tmux:a")
        _ = try await rig.host.deny("tmux:a")
        _ = try await rig.host.allow("tmux:a", tier: .open)
        let sink = RecordingAmbientSink()
        let gate = ambientGate(sink: sink, clock: AmbientTestClock())
        let result: AmbientAdmission = await gate.admission(
            ambientSegment(stream: UUID(), sequence: 0), frameTarget: "tmux:a",
            selection: AmbientSelection(target: "tmux:a"), connection: UUID(), device: nil,
            policyGeneration: snapshot
        )
        #expect(result == .refused(.notAllowed, "ambient target_policy_changed"))
        #expect(sink.events.isEmpty)
    }

    @Test func unchangedTargetWriteRetiresTheOriginalGrant() async throws {
        let rig = try await AmbientPolicyRig.make()
        _ = try await rig.host.allow("tmux:a", tier: .open)
        let result: HostSessionResult = await rig.segment(1)
        let control: ControlPayload = try onlyControl(result)
        #expect(control == .error(code: .notAllowed, message: "ambient target_policy_changed"))
        #expect(rig.sink.segments == [0])
        #expect(rig.sink.endings == [.notAllowed])
    }

    @Test func segmentsUseOnlyTheObservedPolicySnapshot() async throws {
        let rig = try await AmbientPolicyRig.make()
        rig.store.setLoadError(PolicyFileError.unwritable("synthetic"))
        let result: HostSessionResult = await rig.segment(1)
        #expect(result.frames.isEmpty)
        #expect(rig.sink.segments == [0, 1])
        #expect(rig.sink.endings.isEmpty)
        let refreshed: Policy? = await rig.host.refreshedPolicy()
        #expect(refreshed == nil)
        let refused: HostSessionResult = await rig.segment(2)
        let control: ControlPayload = try onlyControl(refused)
        #expect(control == .error(code: .notAllowed, message: "ambient target_policy_changed"))
        #expect(rig.sink.segments == [0, 1])
        #expect(rig.sink.endings == [.notAllowed])
    }

    @Test func targetWriteDuringHandoffPreflightIsRefused() async throws {
        let adapter = GatedListingFakeAdapter(AdapterTarget(name: "a", binding: "binding-a"))
        let registry = Registry()
        try await registry.register(adapter)
        var policy = Policy()
        try policy.allow("tmux:a", binding: "binding-a", tier: .open)
        let host = try HailHost(registry: registry, store: InMemoryPolicyStore(policy))
        let session = HostSession(host: host, authorizer: PersonalTerminalAuthorizer())
        _ = await session.receive(helloFrame())
        _ = await session.receive(sessionFrame(payload: .control(.select(targetID: "tmux:a"))))
        let frame: Frame = sessionFrame(target: "tmux:a", payload: .text(TextPayload(text: "synthetic")))
        await adapter.gateNextListing()
        let handoff = Task {
            let input: AuthorizedInput = try await authorizedInput(session, frame, device: "test")
            return await session.deliver(input)
        }
        await adapter.nextListingArrival()
        _ = try await host.setTier(.confirm, for: "tmux:a")
        _ = try await host.setTier(.open, for: "tmux:a")
        await adapter.releaseListing()
        let outcome: HostDeliveryOutcome = try await handoff.value
        #expect(outcome == .refused(.notAllowed, "target action was refused"))
        let deliveries: [String] = await adapter.deliveries
        #expect(deliveries.isEmpty)
    }

    @Test func residualUntilPR4InFlightLineCompletesButLaterLinesAreRefused() async throws {
        let adapter = GatedFakeAdapter(AdapterTarget(name: "a", binding: "binding-a"))
        let registry = Registry()
        try await registry.register(adapter)
        var policy = Policy()
        try policy.allow("tmux:a", binding: "binding-a", tier: .open)
        let host = try HailHost(
            registry: registry, sanitizing: SanitizePolicy(newlines: .split), store: InMemoryPolicyStore(policy)
        )
        let generation = host.targetPolicy.snapshot(for: "tmux:a")
        async let arrival: Void = adapter.nextArrival()
        let sending = Task {
            try await host.sendAuthorized("one\ntwo", policyGeneration: generation, from: "test",
                                          expectedBinding: nil, context: nil)
        }
        await arrival
        _ = try await host.setTier(.confirm, for: "tmux:a")
        _ = try await host.setTier(.open, for: "tmux:a")
        await adapter.release()
        let expected: HostError = .partial(delivered: ["one"], reason: "target_policy_changed")
        await #expect(throws: expected) { try await sending.value }
        let deliveries: [String] = await adapter.deliveries
        // PR 4 closes this residual: today the suspended adapter line still delivers after retirement.
        #expect(deliveries == ["one"])
    }
}

@Suite(.frozenGuardBudget) struct AmbientPolicyRecoveryTests {
    @Test func freshTextRecoversAfterPolicyReadRepair() async throws {
        let rig = try await AmbientPolicyRig.make()
        let frame: Frame = sessionFrame(target: "tmux:a", payload: .text(TextPayload(text: "synthetic")))
        rig.store.setLoadError(PolicyFileError.unwritable("synthetic"))
        // The first send reaches the host's read boundary and clears cached authority.
        let failed: HostSessionResult = await rig.session.receive(frame)
        let first: ControlPayload = try onlyControl(failed)
        #expect(first == .error(code: .notAllowed, message: "target action was refused"))
        let unreadable: HostSessionResult = await rig.session.receive(frame)
        let second: ControlPayload = try onlyControl(unreadable)
        #expect(second == first)
        let before: [FakeAdapter.Delivery] = await rig.adapter.deliveries
        #expect(before.isEmpty)
        let stale: AuthorizedInput = try await authorizedInput(rig.session, frame, device: "test")
        rig.store.setLoadError(nil)
        // No listing or reselection: the very next fresh input must recover just as the original send path did.
        let recovered: HostSessionResult = await rig.session.receive(frame)
        let after: [FakeAdapter.Delivery] = await rig.adapter.deliveries
        #expect(recovered.frames.isEmpty)
        #expect(after.map(\.text) == ["synthetic"])
        // Recovery can mint a new grant, but cannot revive one minted while authority was unavailable.
        let staleOutcome: HostDeliveryOutcome = await rig.session.deliver(stale)
        let final: [FakeAdapter.Delivery] = await rig.adapter.deliveries
        #expect(staleOutcome == .refused(.notAllowed, "target action was refused"))
        #expect(final == after)
    }
}
