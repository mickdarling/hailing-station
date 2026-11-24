import HailProtocol
import Testing
@testable import HailCore

@MainActor
@Suite struct StationSceneMovedHereTests {
    @Test func disposedStoreRefusesMovedHereCallbacksFromCardsAndControllers() async throws {
        let store = HostConnectionStore(connector: ScriptedConnector())
        let destination = try binding()
        func notice(from kind: String) -> HostReplyEvent {
            let frame = Frame(timestamp: 1, source: "host", payload: .control(.ambientMovedHere(from: kind)))
            return HostReplyEvent(endpointID: destination.hostID, frame: frame)
        }

        let candidate = AmbientListeningControllerTests.Harness().controller
        store.ambientController = candidate
        #expect(store.onAmbientMovedHere != nil)
        store.onAmbientMovedHere = nil
        #expect(store.onAmbientMovedHere == nil)

        // Keep the card's listener active so a late delivery would still change its handoff.
        let card = AmbientListeningControllerTests.Harness()
        let controller = card.controller
        await controller.turnOn(for: destination)
        let forwardToCard: @MainActor (HostEndpoint.Identifier, String?) -> Void = { host, from in
            controller.movedHere(from: from, host: host)
        }
        store.onAmbientMovedHere = forwardToCard
        #expect(store.receiveAmbientNotice(notice(from: "phone")))
        #expect(card.controller.handoff == .movedHere(from: "phone"))

        store.disposeStationScene()
        #expect(store.onAmbientMovedHere == nil)
        store.ambientController = candidate
        #expect(store.ambientController == nil && store.onAmbientMovedHere == nil)
        store.onAmbientMovedHere = forwardToCard
        #expect(store.onAmbientMovedHere == nil)
        #expect(store.receiveAmbientNotice(notice(from: "pad")))
        #expect(card.controller.handoff == .movedHere(from: "phone"))
        await card.controller.turnOff()
    }
}
