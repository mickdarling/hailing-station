import Foundation
import HailProtocol
import Testing
@testable import HailCore

@MainActor
@Suite(.serialized) struct AmbientOwnerDestinationTests {
    enum Stage: CaseIterable, Sendable { case gap, selection, privacy }

    @Test(arguments: Stage.allCases)
    func ownerChangeVetoesPendingRestore(stage: Stage) async throws {
        let run = try OwnerDestinationRun()
        let rig = run.rig
        try await run.start()
        let original = rig.socket
        let ping = try await run.preparePending(stage: stage)
        let sentBeforeOwner = try await rig.socket.sentFrames().count
        #expect(rig.controller.reconnect.isPending)
        await rig.controller.ownerChangedDestination()
        #expect(try await rig.socket.sentFrames().count == sentBeforeOwner)
        run.expectDestinationLoss()
        #expect(rig.notices.map(\.outcome) == [.blocked])
        #expect(rig.notices.map(\.reason) == [.bindingChanged])
        #expect(!rig.controller.reconnect.isPending)
        #expect(run.stops().map { $0.fields[.reason] } == [.token("binding_changed")])

        try await run.answerAfterVeto(stage: stage, ping: ping)
        rig.controller.reconnect.restore(store: rig.store)
        await rig.controller.update(binding: rig.store.ambientBinding(host: rig.endpoint.id, targetID: rig.target.id),
                                    scene: .active)
        for _ in 0..<6 { try rig.capture.yield(sineBuffer()) }
        run.expectDestinationLoss()
        #expect(rig.notices.map(\.outcome) == [.blocked])
        #expect(rig.capture.startCount == 1 && rig.makeCalls == 1 && rig.permissionCalls == 1)
        #expect(rig.released == 1)
        for socket in [original, rig.socket] {
            #expect(try await socket.sentFrames().allSatisfy {
                if case .audio = $0.payload { return false }
                return $0.payload != .control(.setPrivacy(on: false))
            })
        }
        #expect(run.stops().map { $0.fields[.reason] } == [.token("binding_changed")])
        await rig.close()
    }

    @Test(arguments: [true, false])
    func ownerChangeMatchesDestinationLossWithoutRestore(listening: Bool) async throws {
        let owner = try OwnerDestinationRun()
        let loss = try OwnerDestinationRun()
        for run in [owner, loss] { try await run.start(listening: listening) }
        await owner.rig.controller.ownerChangedDestination()
        await loss.rig.controller.destinationLost()
        for run in [owner, loss] {
            #expect(!run.rig.controller.isOn && !run.rig.controller.isListening)
            #expect(run.rig.controller.binding == nil && !run.rig.controller.reconnect.isPending)
            #expect(run.rig.controller.stopReason == (listening ? OwnerDestinationRun.reason : nil))
            #expect(run.rig.unexpected == (listening ? [OwnerDestinationRun.reason] : []))
            #expect(run.rig.notices.isEmpty)
            #expect(run.stops().map { $0.fields[.reason] } == (listening ? [.token("binding_changed")] : []))
            #expect(run.rig.capture.startCount == (listening ? 1 : 0))
            #expect(run.rig.released == (listening ? 1 : 0))
            await run.rig.close()
        }
    }

    @Test func destinationLossStillIgnoresPendingRestore() async throws {
        let run = try OwnerDestinationRun()
        let rig = run.rig
        try await run.start()
        let binding = rig.controller.binding
        try await run.drop()
        await rig.controller.destinationLost()
        #expect(rig.controller.reconnect.isPending && rig.controller.isOn && rig.controller.isListening)
        #expect(rig.controller.binding == binding && rig.controller.stopReason == nil)
        #expect(rig.notices.isEmpty && rig.unexpected.isEmpty && run.stops().isEmpty)
        #expect(rig.capture.stopCount == 0 && rig.released == 0)
        try await run.reconnect()
        try await rig.socket.push(.pong(nonce: try await run.selectionPing()))
        try await run.until { rig.controller.binding != binding }
        for _ in 0..<6 { try rig.capture.yield(sineBuffer()) }
        try await run.until { !rig.controller.reconnect.isPending }
        #expect(rig.notices.map(\.outcome) == [.applied])
        #expect(rig.controller.isListening && rig.capture.startCount == 1)
        await rig.close()
    }
}
