#if os(macOS)
import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientSessionChangeBoundaryTests {
    @Test func routedMismatchDoesNotInvokeTheOwnTargetNoticeOrEndAStream() async throws {
        let rig = try await ConfiguredAmbientRig.make(routes: VoiceRouteRig.routes(),
            capabilities: AmbientSessionChangeNoticeTests.capabilities)
        let changed = Mutex(false)
        do {
            await rig.base.adapter.setTargets([AdapterTarget(name: "scratch", binding: "s"),
                                               AdapterTarget(name: "deck", binding: "replacement")])
            let dispatcher = AmbientListenerDispatcher(listener: rig.listener, audit: nil,
                selection: await rig.session.selectionGeneration, streamTarget: ConfiguredAmbientRig.target,
                binding: "s", bindingChanged: { changed.withLock { $0 = true } })
            let request = LocalDispatchRequest(connection: rig.connection, target: VoiceRouteRig.deck,
                                               binding: "d", text: "synthetic request")
            await #expect(throws: LocalDispatchRefusal.bindingMismatch) {
                try await dispatcher.dispatch(request, routed: true)
            }
            #expect(!changed.withLock { $0 })
            #expect(await rig.base.adapter.deliveries.isEmpty)
            try await barrier(on: rig.pair.sockets[0], step: "routed mismatch has no own-target notice or stop")
        } catch {
            await rig.cleanUp()
            throw error
        }
        await rig.cleanUp()
    }

    @Test func anOlderDeviceGetsTheSessionStopWithoutAnUnsupportedRequestRefusal() async throws {
        let rig = try await ConfiguredAmbientRig.make()
        do {
            try await rig.rebind()
            let result = await rig.segment(UUID(), final: true)
            #expect(try onlyControl(result) == AmbientSessionChangeNoticeTests.stopped)
            #expect(result.disposition == .keepOpen)
            #expect(rig.sink.events.isEmpty)
            #expect(await rig.base.adapter.deliveries.isEmpty)
        } catch {
            await rig.cleanUp()
            throw error
        }
        await rig.cleanUp()
    }
}
#endif
