#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientMidstreamRebindTests {
    @Test func bindingMismatchIsTerminalAndReallowCannotRedirectOrReplay() async throws {
        let rig = try await ConfiguredAmbientRig.make(behavior: RightyoAmbientPendingInputTests.twoRequests)
        do {
            let stream = UUID()
            #expect(await rig.segment(stream).frames.isEmpty)
            let scope = try rig.scope()
            try await rig.rebind()
            try RightyoAmbientPendingInputTests.release(rig.fake, "go1")
            #expect(await eventually {
                rig.events.details("ambient_ended").contains { $0 == "dispatch bindingMismatch" }
            })
            #expect(await eventually { await rig.gate.activeStream == nil })
            _ = try await rig.base.host.allow(ConfiguredAmbientRig.target, tier: .open)
            try RightyoAmbientPendingInputTests.release(rig.fake, "go2")
            await boundedSettle(rig.router)
            #expect(!((await rig.segment(stream, 1)).frames.isEmpty))
            #expect(await rig.base.adapter.deliveries.isEmpty)
            await #expect(throws: (any Error).self) {
                try await rig.dispatcher(scope).dispatch(rig.request(scope))
            }
            #expect(await rig.base.adapter.deliveries.isEmpty)
            try rewriteFake(rig.fake, ambientEchoAtEOF)
            #expect(await rig.segment(UUID(), final: true).frames.isEmpty)
            await boundedSettle(rig.router)
            #expect(await rig.base.adapter.deliveries.map(\.binding) == ["replacement"])
        } catch {
            await rig.cleanUp()
            throw error
        }
        await rig.cleanUp()
    }

    @Test func confirmationTierABACannotHoldAnOldStreamsQueuedRequest() async throws {
        let rig = try await ConfiguredAmbientRig.make(behavior: "/bin/cat > /dev/null",
                                                      capabilities: [HeldRequests.capability])
        do {
            #expect(await rig.segment(UUID()).frames.isEmpty)
            let scope = try rig.scope()
            _ = try await rig.base.host.deny(ConfiguredAmbientRig.target)
            _ = try await rig.base.host.allow(ConfiguredAmbientRig.target, tier: .confirm)
            await #expect(throws: LocalDispatchRefusal.deliveryRefused) {
                try await rig.dispatcher(scope).dispatch(rig.request(scope))
            }
            #expect(await rig.base.host.heldRequests.entries.isEmpty)
            #expect(await rig.base.adapter.deliveries.isEmpty)
        } catch {
            await rig.cleanUp()
            throw error
        }
        await rig.cleanUp()
    }

    @Test(arguments: [false, true])
    func queuedDispatchCannotReviveAfterDenyReallowABA(reload: Bool) async throws {
        let rig = try await ConfiguredAmbientRig.make(behavior: "/bin/cat > /dev/null")
        let queued = PolicyHandoffSleepGate()
        do {
            #expect(await rig.segment(UUID()).frames.isEmpty)
            let scope = try rig.scope()
            let generation = try #require(scope.policyGeneration)
            let dispatcher = rig.dispatcher(scope), request = rig.request(scope)
            let sending = Task {
                await queued.sleep()
                do { _ = try await dispatcher.dispatch(request); return false } catch { return true }
            }
            try #require(await eventually { await queued.isWaiting() })
            _ = try await rig.base.host.deny(ConfiguredAmbientRig.target)
            _ = try await rig.base.host.allow(ConfiguredAmbientRig.target, tier: .open)
            // The policy entry and live binding match again, but the original generation stays retired.
            #expect(generation.performIfCurrent({ true }) != true)
            if reload {
                #expect(await rig.router.reload() == .reloaded)
                #expect(rig.router.state.withLock {
                    $0.active?.policyGeneration?.isSameGeneration(as: generation) == true
                })
            }
            await queued.fire()
            #expect(await sending.value)
            #expect(await rig.base.adapter.deliveries.isEmpty)
            let pipeline = rig.router.state.withLock { $0.active?.pipeline }
            pipeline?.finishInput()
            await boundedSettle(rig.router)
            #expect(await rig.base.adapter.deliveries.isEmpty)
        } catch {
            await queued.fire()
            await rig.cleanUp()
            throw error
        }
        await rig.cleanUp()
    }
}
#endif
