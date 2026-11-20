#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct ConfiguredAmbientHijackTests {
    @Test func anUnapprovedNameHolderCannotOpenAStream() async throws {
        let rig = try await ConfiguredAmbientRig.make()
        do {
            try await rig.rebind()
            let result = await rig.segment(UUID(), final: true)
            #expect(!result.frames.isEmpty)
            #expect(rig.sink.events.isEmpty)
            #expect(rig.router.liveRuns == 0)
            #expect(await rig.gate.activeStream == nil)
            #expect(await rig.base.adapter.deliveries.isEmpty)
        } catch {
            await rig.cleanUp()
            throw error
        }
        await rig.cleanUp()
    }

    @Test(arguments: [nil, ""] as [String?])
    func anUnboundConfiguredScopeCannotUseTheStartupHint(binding: String?) async throws {
        let rig = try await ConfiguredAmbientRig.make()
        let stream = UUID()
        rig.router.ambientAudio(.started(stream: stream, connection: rig.connection,
                                         target: ConfiguredAmbientRig.target, binding: binding))
        rig.router.ambientAudio(.ended(stream: stream, reason: .final))
        await boundedSettle(rig.router)
        #expect(rig.events.details("ambient_started").isEmpty)
        #expect(await rig.base.adapter.deliveries.isEmpty)
        await rig.cleanUp()
    }

    @Test(arguments: ["missing", "unbound", "empty", "dead", "denied", "unreadable"])
    func unavailableAuthorityNeverFallsBackToTheStartupHint(reason: String) async throws {
        let rig = try await ConfiguredAmbientRig.make()
        do {
            switch reason {
            case "missing": await rig.base.adapter.setTargets([])
            case "unbound": await rig.base.adapter.setTargets([AdapterTarget(name: "scratch")])
            case "empty": await rig.base.adapter.setTargets([AdapterTarget(name: "scratch", binding: "")])
            case "dead": await rig.base.adapter.setTargets([AdapterTarget(name: "scratch", alive: false, binding: "s")])
            case "denied": _ = try await rig.base.host.deny(ConfiguredAmbientRig.target)
            default:
                rig.base.store.setLoadError(PolicyFileError.unwritable("synthetic"))
                #expect(await rig.base.host.refreshedPolicy() == nil)
            }
            let result = await rig.segment(UUID(), final: true)
            #expect(try onlyControl(result) == .error(code: .notAllowed,
                message: "ambient target is not allowed — run haild targets allow on the Mac"))
            #expect(rig.sink.events.isEmpty)
            #expect(rig.router.liveRuns == 0)
            #expect(await rig.base.adapter.deliveries.isEmpty)
        } catch {
            await rig.cleanUp()
            throw error
        }
        await rig.cleanUp()
    }

    @Test(arguments: [0, 1, 2])
    func swapAfterAdmissionNeverDeliversToTheUnapprovedHolder(reloads: Int) async throws {
        let rig = try await ConfiguredAmbientRig.make(behavior: RightyoAmbientPendingInputTests.twoRequests)
        do {
            let stream = UUID()
            #expect(await rig.segment(stream).frames.isEmpty)
            try await rig.rebind()
            for _ in 0..<reloads {
                #expect(await rig.router.reload() == .reloaded)
                #expect(rig.router.state.withLock { $0.active?.binding == "s" })
                try #require(await eventually { rig.router.liveRuns == 1 })
            }
            try RightyoAmbientPendingInputTests.release(rig.fake, "go1")
            #expect(await eventually {
                rig.events.details("ambient_ended").contains { $0 == "dispatch bindingMismatch" }
            })
            await boundedSettle(rig.router)
            #expect(await rig.base.adapter.deliveries.isEmpty)
            #expect(!rig.events.details("ambient_ended").contains { $0.contains("delivered=1") })
        } catch {
            await rig.cleanUp()
            throw error
        }
        await rig.cleanUp()
    }
}
#endif
