import Foundation
import Testing
@testable import HailDaemonKit

// At most one synchronous profile getter blocks a cooperative executor worker at a time.
@Suite(.serialized) struct ProviderInputShapeAuthorityTests {
    @Test(arguments: [false, true])
    func cancellationDuringShapeHopPreservesActualConfirmation(legacy: Bool) async throws {
        let profile = InputShapeProfile(legacy ? .lineOriented : .singleLineContextual)
        let adapter = InputShapeAdapter(profile: profile)
        let rig = try await InputShapeRig.make(adapter: adapter, tier: .confirm, rate: 1)
        let text = "invented input"
        let readBack = try await rig.readBack(text)
        profile.hold()
        let send = Task {
            if legacy {
                return try await rig.host.send(text, to: InputShapeRig.target, confirmedHash: readBack.hash)
            }
            return try await rig.host.send(text, context: rig.context, confirmedHash: readBack.hash)
        }
        await profile.arrivals.wait()
        send.cancel()
        profile.release()
        await #expect(throws: CancellationError.self) { try await send.value }
        #expect(await adapter.contextual.isEmpty)
        #expect(await adapter.legacy.isEmpty)
        if legacy {
            #expect(try await rig.host.send(text, to: InputShapeRig.target, confirmedHash: readBack.hash) ==
                .delivered([text]))
        } else {
            #expect(try await rig.host.send(text, context: rig.context, confirmedHash: readBack.hash) ==
                .delivered([text]))
        }
    }

    @Test(arguments: [false, true], [0, 1, 2, 3])
    func shapeHopRevalidatesExternalPolicyAndLockdown(legacy: Bool, change: Int) async throws {
        let profile = InputShapeProfile(legacy ? .lineOriented : .singleLineContextual)
        let adapter = InputShapeAdapter(profile: profile)
        let rig = try await InputShapeRig.make(adapter: adapter)
        profile.hold()
        let send = Task {
            if legacy { return try await rig.host.send("invented input", to: InputShapeRig.target) }
            return try await rig.host.send("invented input", context: rig.context)
        }
        await profile.arrivals.wait()
        var policy = rig.store.stored
        if change == 0 { policy.deny(InputShapeRig.target) }
        if change == 1 { _ = policy.setTier(.locked, for: InputShapeRig.target) }
        if change == 2 { try policy.allow(InputShapeRig.target, binding: "replacement", tier: .open) }
        if change == 3 { _ = await rig.host.engageLockdown(reason: "invented shape test") }
        rig.store.overwrite(policy)
        profile.release()
        let denial: Denial = switch change {
        case 0: .notAllowed(InputShapeRig.target)
        case 1: .locked(InputShapeRig.target)
        case 2: .rebound(InputShapeRig.target)
        default: .lockdown
        }
        await #expect(throws: HostError.denied(denial)) { try await send.value }
        #expect(await adapter.contextual.isEmpty)
        #expect(await adapter.legacy.isEmpty)
    }

    @Test(arguments: [0, 1, 2]) func providerAndBindingMismatchesDoNotBurnConfirmation(mode: Int) async throws {
        let adapter = InputShapeAdapter()
        let rig = try await InputShapeRig.make(adapter: adapter, tier: .confirm, rate: 1)
        let readBack = try await rig.readBack("invented input")
        let binding = try ProviderSessionBinding(hostID: rig.context.binding.hostID,
            providerID: mode == 0 ? "other" : mode == 1 ? "shape:group" : "shape", targetID: InputShapeRig.target,
            sessionID: mode == 2 ? "wrong-binding" : rig.context.binding.sessionID)
        let wrong = ProviderTurnContext(utteranceID: UUID(), connectionID: UUID(), binding: binding)
        if mode == 2 {
            await #expect(throws: HostError.denied(.rebound(InputShapeRig.target))) {
                try await rig.host.send("invented input", context: wrong, confirmedHash: readBack.hash)
            }
        } else {
            await #expect(throws: ProviderContractError.wrongContext) {
                try await rig.host.send("invented input", context: wrong, confirmedHash: readBack.hash)
            }
        }
        #expect(await adapter.contextual.isEmpty)
        #expect(try await rig.host.send("invented input", context: rig.context, confirmedHash: readBack.hash) ==
            .delivered(["invented input"]))
    }

    @Test func adapterStillEnforcesBindingImmediatelyBeforeItsSideEffect() async throws {
        let profile = InputShapeProfile()
        let adapter = InputShapeAdapter(profile: profile)
        let rig = try await InputShapeRig.make(adapter: adapter)
        profile.hold()
        let send = Task { try await rig.host.send("invented input", context: rig.context) }
        await profile.arrivals.wait()
        await adapter.rebind()
        profile.release()
        await #expect(throws: AdapterError.rebound("session")) { try await send.value }
        #expect(await adapter.contextual.isEmpty)
        #expect(await adapter.legacy.isEmpty)
    }

    @Test func committedNoncooperativeSingleLineRetainsSentEvidenceAfterCancellation() async throws {
        let adapter = InputShapeAdapter(cancelsAtEntry: true)
        let rig = try await InputShapeRig.make(adapter: adapter, tier: .confirm)
        let readBack = try await rig.readBack("invented input")
        let send = Task {
            try await rig.coordinator.submit("invented input", utteranceID: UUID(), confirmedHash: readBack.hash)
        }
        guard case .sent(let turn) = try await send.value else { Issue.record("no sent evidence"); return }
        #expect(await rig.coordinator.state(for: turn.id) == .sent)
        #expect(await adapter.contextual.map(\.context) == [turn])
        #expect(await adapter.legacy.isEmpty)
    }

    @Test func lineOrientedPartialFailureStillPreservesKnownLinesWithoutSentPromotion() async throws {
        let adapter = InputShapeAdapter(profile: .init(.lineOriented), failAfter: 1)
        let rig = try await InputShapeRig.make(adapter: adapter)
        await #expect(throws: HostError.partial(delivered: ["invented first"], reason: "adapter delivery failed")) {
            try await rig.coordinator.submit("invented first\ninvented second", utteranceID: UUID())
        }
        let proposed = try #require(await adapter.contextual.first?.context)
        #expect(await rig.coordinator.state(for: proposed.id) == nil)
        #expect(await adapter.contextual.map(\.text) == ["invented first"])
    }

    @Test func sanitizerRefusalStillPrecedesShapeAdmission() async throws {
        let adapter = InputShapeAdapter()
        let rig = try await InputShapeRig.make(adapter: adapter, rate: 1, sanitizing: .init())
        await #expect(throws: HostError.refused(.containsLineBreak)) {
            try await rig.host.send("invented first\ninvented second", context: rig.context)
        }
        #expect(await adapter.contextual.isEmpty)
        #expect(try await rig.host.send("invented input", context: rig.context) == .delivered(["invented input"]))
    }
}
