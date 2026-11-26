import Foundation
import HailProtocol
import Testing
@testable import HailCore

@MainActor
struct TalkTextDispatchTests {
    @Test(arguments: [false, true])
    func switchingMacAfterValidationRefusesBothSockets(withPaste: Bool) async throws {
        let first = try await TalkDestinationStoreFixture.make()
        let other = try endpoint("mac-b", "ws://127.0.0.1:8766")
        let second = try await TalkDestinationStoreFixture.connect(
            other, store: first.store, connector: first.connector
        )
        try await first.select("target")
        let admitted = try first.binding("target")
        // This is the same validated dispatch the store hands across the actor boundary.
        let connection = try first.store.connection(for: admitted)
        try await first.store.selectTarget(host: other.id, targetID: "target")
        let pasted = withPaste ? try PastedDraft("fixture attachment") : nil
        await #expect(throws: TalkSendRefusal.destinationChanged) {
            try await connection.sendFinalText("old turn", pasted: pasted, to: "target", binding: admitted)
        }
        #expect(try await first.socket.transcripts().isEmpty)
        #expect(try await second.transcripts().isEmpty)
        let current = try #require(first.store.talkBinding(for: .init(endpointID: other.id, targetID: "target")))
        try await first.store.sendFinalText("new turn", pasted: pasted, to: current)
        let frames = try await second.transcripts()
        #expect(frames == [TextPayload(text: "new turn", pasted: pasted.map { PastedText(text: $0.text) })])
        await first.store.disconnect(other.id)
        await first.store.disconnect(first.host.id)
    }

    @Test(arguments: [false, true])
    func renameAfterStoreValidationRefusesAtDispatch(withPaste: Bool) async throws {
        let host = try await TalkDestinationStoreFixture.make()
        try await host.select("a")
        let admitted = try host.binding("a")
        let connection = try host.store.connection(for: admitted)
        let pasted = withPaste ? try PastedDraft("fixture attachment") : nil
        // Exercise the actor before its target-list update reaches the store and retires the request.
        await connection.setUnpublishedTarget(TargetInfo(id: "a", kind: "tmux", name: "Renamed", alive: true))
        #expect(admitted.request.isCurrent)
        await #expect(throws: TalkSendRefusal.destinationChanged) {
            try await connection.sendFinalText("old turn", pasted: pasted, to: "a", binding: admitted)
        }
        #expect(try await host.socket.transcripts().isEmpty)
        await host.store.disconnect(host.host.id)
    }

    @Test(arguments: [false, true])
    func retirementDuringFramePreparationRefusesAndRetractsTheTurn(withPaste: Bool) async throws {
        let host = try await TalkDestinationStoreFixture.make(wallNow: {
            DispatchClock.duringEncoding?()
            return 1
        })
        try await host.select("a")
        let binding = try host.binding("a")
        let pasted = withPaste ? try PastedDraft("fixture attachment") : nil
        // The real frame clock runs on the connection actor after its first check. Retire the same
        // request that a store selection retires, only in this send's task.
        let retire: @Sendable () -> Void = { binding.request.invalidate() }
        await DispatchClock.$duringEncoding.withValue(retire) {
            await #expect(throws: TalkSendRefusal.destinationChanged) {
                try await host.store.sendFinalText("fixture", pasted: pasted, to: binding)
            }
        }
        #expect(!binding.request.isCurrent)
        #expect(try await host.socket.transcripts().isEmpty)
        #expect(host.store.conversation.entries.isEmpty)
        await host.store.disconnect(host.host.id)
    }

    @Test func restoredTargetAcceptsOnlyAFreshRecording() async throws {
        let host = try await TalkDestinationStoreFixture.make()
        try await host.select("a")
        let admitted = try host.binding("a")
        let connection = try host.store.connection(for: admitted)
        try await host.socket.base.push(.targets([]))
        await arrivalObserved { host.store.talkBinding(for: admitted.destination) == nil }
        try await host.socket.base.push(.targets([TargetInfo(id: "a", kind: "tmux", name: "Fixture", alive: true)]))
        await arrivalObserved { host.store.talkBinding(for: admitted.destination) != nil }
        let current = try host.binding("a")
        #expect(current != admitted && admitted.connectionGeneration == current.connectionGeneration)
        await #expect(throws: TalkSendRefusal.destinationChanged) {
            try await connection.sendFinalText("old turn", pasted: nil, to: "a", binding: admitted)
        }
        try await host.store.sendFinalText("new turn", pasted: nil, to: current)
        #expect(try await host.socket.transcripts().map(\.text) == ["new turn"])
        await host.store.disconnect(host.host.id)
    }

    @Test(arguments: [false, true])
    func replacementConnectionCannotUseAnAdmittedDispatch(withPaste: Bool) async throws {
        let first = try await TalkDestinationStoreFixture.make()
        let replacement = try await TalkDestinationStoreFixture.make()
        try await first.select("a")
        try await replacement.select("a")
        let admitted = try first.binding("a"), current = try replacement.binding("a")
        #expect(admitted.destination == current.destination && admitted.selection == current.selection)
        #expect(admitted.connectionGeneration != current.connectionGeneration)
        let connection = try replacement.store.connection(for: current)
        let pasted = withPaste ? try PastedDraft("fixture attachment") : nil
        // Keep the old store request valid to exercise the socket actor's independent generation check.
        await #expect(throws: TalkSendRefusal.destinationChanged) {
            try await connection.sendFinalText("fixture", pasted: pasted, to: "a", binding: admitted)
        }
        #expect(admitted.request.isCurrent && current.request.isCurrent)
        #expect(try await replacement.socket.transcripts().isEmpty)
        await first.store.disconnect(first.host.id)
        await replacement.store.disconnect(replacement.host.id)
    }
}

private enum DispatchClock {
    @TaskLocal static var duringEncoding: (@Sendable () -> Void)?
}

private extension HostConnection {
    func setUnpublishedTarget(_ target: TargetInfo) {
        snapshot.targets = [target]
    }
}
