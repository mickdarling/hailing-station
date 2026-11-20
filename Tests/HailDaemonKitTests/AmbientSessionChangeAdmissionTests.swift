#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientSessionChangeAdmissionTests {
    @Test func aNewRefusalUsesItsOpeningGrantAndPreservesTheOlderChildsRetainedGeneration() async throws {
        let rig = try await ConfiguredAmbientRig.make(capabilities: AmbientSessionChangeNoticeTests.capabilities)
        do {
            let stream = UUID()
            #expect(await rig.segment(stream).frames.isEmpty)
            try #require(await eventually { rig.router.activeStream == stream })
            let original = try #require(await rig.session.ambientPolicyGeneration)
            try await rig.rebind("approved", allow: true)
            try await rig.rebind("unapproved")
            let refused = await rig.segment(UUID())
            #expect(refused.frames.map(\.payload) == [
                .control(AmbientSessionChangeNoticeTests.notice), .control(AmbientSessionChangeNoticeTests.stopped)
            ])
            let retained = try #require(await rig.session.ambientPolicyGeneration)
            #expect(retained.isSameGeneration(as: original))
            #expect(retained.performIfCurrent { true } == nil)
            #expect(await rig.gate.activeStream == stream)
            #expect(await rig.base.adapter.deliveries.isEmpty)
        } catch {
            await rig.cleanUp()
            throw error
        }
        await rig.cleanUp()
    }

    @Test(arguments: ["missing", "dead", "nil", "empty"])
    func unavailableMidstreamBindingsKeepTheirPriorEnding(kind: String) async throws {
        let rig = try await ConfiguredAmbientRig.make(behavior: RightyoAmbientPendingInputTests.twoRequests,
            capabilities: AmbientSessionChangeNoticeTests.capabilities)
        do {
            let stream = UUID()
            #expect(await rig.segment(stream).frames.isEmpty)
            try #require(await eventually { rig.router.activeStream == stream })
            let targets: [AdapterTarget]
            switch kind {
            case "missing": targets = []
            case "dead": targets = [AdapterTarget(name: "scratch", alive: false, binding: "s")]
            case "nil": targets = [AdapterTarget(name: "scratch", binding: nil)]
            default: targets = [AdapterTarget(name: "scratch", binding: "")]
            }
            await rig.base.adapter.setTargets(targets)
            try RightyoAmbientPendingInputTests.release(rig.fake, "go1")
            let stop = try await receiveFrame(on: rig.pair.sockets[0], step: "prior unavailable-binding ending")
            #expect(stop.payload == .control(.error(code: .notAllowed,
                message: "ambient stopped: dispatch bindingMismatch")))
            #expect(await eventually { rig.router.liveRuns == 0 })
            #expect(rig.events.details("ambient_delivery_refused").isEmpty)
            #expect(await rig.base.adapter.deliveries.isEmpty)
            try await barrier(on: rig.pair.sockets[0], step: "unavailable binding has no session-change notice")
        } catch {
            await rig.cleanUp()
            throw error
        }
        await rig.cleanUp()
    }
}
#endif
