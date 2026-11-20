import Foundation
import HailProtocol
import Testing
@testable import HailCore

@MainActor
@Suite(.timeLimit(.minutes(1))) struct SessionUpdateDisplayBufferTests {
    @Test(arguments: [false, true])
    func socketCardsBeforeTargetsWaitForReadinessWithoutRenewingSpeech(reconnectPending: Bool) async throws {
        let rig = try await CardsArrivalRig.make(targets: nil)
        let controller = AmbientListeningController(requestPermission: { true },
            makeStreamer: { AmbientAudioStreamer(capture: FakeAudioCapture(), send: $0) },
            releaseSession: {}, send: { _, _ in })
        if reconnectPending {
            rig.store.ambientController = controller
            await controller.turnOn(for: AmbientAudioBinding(
                hostID: rig.endpoint.id, targetID: CardsArrivalRig.target.id,
                connectionGeneration: rig.generation, selection: 0))
            controller.reconnect.drop(try #require(rig.store.snapshots[rig.endpoint.id]), store: rig.store)
            #expect(controller.reconnect.isPending)
        }
        let descriptor = rig.descriptor()
        let card = rig.card(descriptor)
        try await rig.socket.push(FrameCoding.encode(card.frame))
        try await rig.socket.push(FrameCoding.encode(card.frame))
        await rig.socket.flush()
        #expect(rig.store.conversation.entries.isEmpty)
        #expect(rig.store.sessionUpdateDisplay.pending.map(\.event.frame.id) == [card.frame.id])
        #expect(rig.store.proactiveSpeechReceipts.first?.allowed == false)
        try await rig.socket.push(.targets([CardsArrivalRig.target]))
        await rig.socket.flush()
        #expect(rig.store.sessionUpdateDisplay.pending.isEmpty)
        #expect(rig.store.conversation.entries.map(\.text) == ["Synthetic decision."])
        #expect(rig.store.conversation.entries.allSatisfy { !$0.spoken })
        #expect(!rig.store.permitsProactiveSpeech(rig.endpoint.id, generation: rig.generation, descriptor: descriptor))
        try await rig.socket.push(FrameCoding.encode(card.frame))
        await rig.socket.flush()
        #expect(rig.store.conversation.entries.count == 1)
        #expect(rig.store.proactiveSpeechReceipts.first?.allowed == false)
        await controller.turnOff()
        await rig.store.disconnect(rig.endpoint.id)
    }

    @Test func socketBufferIsBoundedEvictsOldestAndDrainsInArrivalOrder() async throws {
        let rig = try await CardsArrivalRig.make(targets: nil)
        var logs: [String] = []
        rig.store.sessionUpdateDisplay.log = { logs.append($0) }
        let cards = (0...SessionUpdateDisplayBuffer.limit).map { _ in rig.card(rig.descriptor()) }
        for card in cards {
            try await rig.socket.push(FrameCoding.encode(card.frame))
            await rig.socket.flush()
            #expect(rig.store.sessionUpdateDisplay.pending.count <= SessionUpdateDisplayBuffer.limit)
        }
        #expect(rig.store.conversation.entries.isEmpty)
        #expect(rig.store.sessionUpdateDisplay.pending.map(\.event.frame.id) == cards.dropFirst().map(\.frame.id))
        #expect(logs == ["session_update_display_buffer evicted oldest card at capacity"])
        try await rig.socket.push(.targets([CardsArrivalRig.target]))
        await rig.socket.flush()
        let expected = cards.dropFirst().compactMap { event -> String? in
            guard case .control(.sessionUpdate(let update, _, _, _, _)) = event.frame.payload else { return nil }
            return "\(rig.endpoint.id)|\(update.uuidString.lowercased())"
        }
        #expect(rig.store.conversation.entries.map(\.id) == expected)
        #expect(rig.store.sessionUpdateDisplay.pending.isEmpty)
        #expect(rig.store.conversation.entries.allSatisfy { !$0.spoken })
        await rig.store.disconnect(rig.endpoint.id)
    }

    @Test(arguments: ["replacement", "retirement"])
    func socketTargetSnapshotDropsHeldCardWithContentFreeLog(change: String) async throws {
        let rig = try await CardsArrivalRig.make(targets: nil)
        var logs: [String] = []
        rig.store.sessionUpdateDisplay.log = { logs.append($0) }
        try await rig.socket.push(FrameCoding.encode(rig.card(rig.descriptor()).frame))
        await rig.socket.flush()
        #expect(rig.store.sessionUpdateDisplay.pending.count == 1)
        let target = TargetInfo(id: change == "replacement" ? "tmux:other" : CardsArrivalRig.target.id,
                                kind: "tmux", name: "Other", alive: change == "replacement")
        try await rig.socket.push(.targets([target]))
        await rig.socket.flush()
        #expect(rig.store.sessionUpdateDisplay.pending.isEmpty)
        #expect(logs == ["session_update_display_buffer dropped unavailable target or capability card"])
        try await rig.socket.push(.targets([CardsArrivalRig.target]))
        await rig.socket.flush()
        #expect(rig.store.conversation.entries.isEmpty, "restoring a target cannot revive a retired card")
        await rig.store.disconnect(rig.endpoint.id)
    }

    @Test func socketReconnectGenerationDropsOldHeldCardWithContentFreeLog() async throws {
        let rig = try await CardsArrivalRig.make(targets: nil, sleep: { _ in })
        var logs: [String] = []
        rig.store.sessionUpdateDisplay.log = { logs.append($0) }
        try await rig.socket.push(FrameCoding.encode(rig.card(rig.descriptor()).frame))
        await rig.socket.flush()
        #expect(rig.store.sessionUpdateDisplay.pending.count == 1)
        let socket = ArrivalSocket()
        await rig.connector.enqueue(.socket(socket), for: rig.endpoint.url)
        try await socket.push(.hello(HelloInfo(versions: VersionNegotiation.supported,
                                               capabilities: CardsArrivalRig.capabilities, deviceName: "Replacement")))
        try await socket.push(.targets([CardsArrivalRig.target]))
        await rig.socket.fail()
        await socket.flush()
        #expect(rig.store.snapshots[rig.endpoint.id]?.connectionGeneration != rig.generation)
        #expect(rig.store.sessionUpdateDisplay.pending.isEmpty)
        #expect(rig.store.conversation.entries.isEmpty)
        #expect(logs == ["session_update_display_buffer dropped stale connection card"])
        await rig.store.disconnect(rig.endpoint.id)
    }

    @Test(arguments: ["host", "connection", "removal"])
    func replacingOrRetiringConnectionDropsSocketHeldCardWithContentFreeLog(change: String) async throws {
        let rig = try await CardsArrivalRig.make(targets: nil)
        var logs: [String] = []
        rig.store.sessionUpdateDisplay.log = { logs.append($0) }
        try await rig.socket.push(FrameCoding.encode(rig.card(rig.descriptor()).frame))
        await rig.socket.flush()
        #expect(rig.store.sessionUpdateDisplay.pending.count == 1)
        let replacement = change == "host" ? try endpoint(rig.endpoint.id, "ws://127.0.0.1:8766") : rig.endpoint
        let socket = ArrivalSocket()
        await rig.connector.enqueue(.socket(socket), for: replacement.url)
        if change == "removal" { await rig.store.remove(rig.endpoint.id) }
        if change == "connection" { await rig.store.disconnect(rig.endpoint.id) }
        if change != "connection" { await rig.store.upsert(replacement) }
        #expect(rig.store.sessionUpdateDisplay.pending.isEmpty)
        #expect(logs == ["session_update_display_buffer dropped retired connection card"])
        try await socket.push(.hello(HelloInfo(versions: VersionNegotiation.supported,
                                               capabilities: CardsArrivalRig.capabilities, deviceName: "Replacement")))
        try await socket.push(.targets([CardsArrivalRig.target]))
        await rig.store.connect(replacement.id)
        await socket.flush()
        #expect(rig.store.snapshots[replacement.id]?.connectionGeneration != rig.generation)
        #expect(rig.store.conversation.entries.isEmpty)
        await rig.store.disconnect(replacement.id)
    }
}
