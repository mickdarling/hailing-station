import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// #1028 FAIL-BEFORE: synthetic PCM only; no listener sockets or recorded content.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientPolicyRevocationTests {
    @Test(arguments: AmbientPolicyWrite.revocations, [false, true])
    fileprivate func targetWritesRefuseNextSegmentAndSendTerminalStop(
        _ change: AmbientPolicyWrite, _ externally: Bool
    ) async throws {
        let rig = try await AmbientPolicyRig.make()
        try await rig.write(change, target: "tmux:a", externally: externally)
        let refused: HostSessionResult = await rig.segment(1)

        #expect(rig.sink.segments == [0])
        let endings: [AmbientStreamEndReason] = rig.sink.endings
        #expect(endings.count == 1)
        if let reason = endings.first {
            #expect(rig.sink.events.last == .ended(stream: rig.stream, reason: reason))
            #expect(reason != .final && reason != .idle && reason != .superseded)
        }
        let active: UUID? = await rig.gate.activeStream
        #expect(active == nil)
        let deliveries: [FakeAdapter.Delivery] = await rig.adapter.deliveries
        #expect(deliveries.isEmpty)

        // The ambient prefix preserves the connection; omitting `stopped:` makes the refusal non-transient.
        let expected: ControlPayload = .error(code: .notAllowed, message: "ambient target_policy_changed")
        let controls: [ControlPayload] = refused.frames.compactMap { frame in
            guard case .control(let control) = frame.payload else { return nil }
            return control
        }
        #expect(controls == [expected])
        #expect(refused.frames.count == 1)
        #expect(refused.disposition == .keepOpen)
    }

    @Test(arguments: AmbientPolicyWrite.revocations, [false, true])
    fileprivate func preauthorizedHandoffIsRefusedAfterTargetWrite(
        _ change: AmbientPolicyWrite, _ externally: Bool
    ) async throws {
        let rig = try await AmbientPolicyRig.make()
        let sleep = PolicyHandoffSleepGate()
        let handoff = Task { try await rig.pendingHandoff(sleep) }
        await waitUntil { await sleep.isWaiting() }
        do {
            try await rig.write(change, target: "tmux:a", externally: externally)
        } catch {
            await sleep.fire()
            _ = try? await handoff.value
            throw error
        }
        await sleep.fire()
        let outcome: HostDeliveryOutcome = try await handoff.value
        let refused: Bool = switch outcome {
        case .refused, .confirmationRequired: true
        default: false
        }
        #expect(refused)
        let deliveries: [FakeAdapter.Delivery] = await rig.adapter.deliveries
        #expect(deliveries.isEmpty)
    }

    @Test(arguments: AmbientPolicyWrite.allCases, [false, true])
    fileprivate func otherTargetWritesLeaveStreamAndHandoffAccepting(
        _ change: AmbientPolicyWrite, _ externally: Bool
    ) async throws {
        let rig = try await AmbientPolicyRig.make(allowB: change != .allow)
        let sleep = PolicyHandoffSleepGate()
        let handoff = Task { try await rig.pendingHandoff(sleep) }
        await waitUntil { await sleep.isWaiting() }
        do {
            try await rig.write(change, target: "tmux:b", externally: externally)
        } catch {
            await sleep.fire()
            _ = try? await handoff.value
            throw error
        }
        let next: HostSessionResult = await rig.segment(1)
        #expect(next.frames.isEmpty)
        #expect(next.disposition == .keepOpen)
        #expect(rig.sink.segments == [0, 1])
        #expect(rig.sink.endings.isEmpty)
        let active: UUID? = await rig.gate.activeStream
        #expect(active == rig.stream)
        await sleep.fire()
        let outcome: HostDeliveryOutcome = try await handoff.value
        #expect(outcome == .delivered(request: nil))
        let deliveries: [FakeAdapter.Delivery] = await rig.adapter.deliveries
        #expect(deliveries.count == 1)
        #expect(deliveries.first?.target == "a")
    }

    private func waitUntil(_ predicate: @Sendable () async -> Bool) async {
        let deadline = ContinuousClock.now.advanced(by: .seconds(10))
        while ContinuousClock.now < deadline {
            if await predicate() { return }
            await Task.yield()
        }
        Issue.record("The policy handoff did not reach its bounded gate")
    }
}
