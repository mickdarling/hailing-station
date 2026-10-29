import Foundation
import HailProtocol
import Testing
@testable import HailCore

@MainActor
@Suite(.serialized) struct AmbientReconnectSelectFailureTests {
    @Test(arguments: SelectionTransportFailure.allCases)
    func selectionFailureBeforeObservedDropFlapsAndRestores(failure: SelectionTransportFailure) async throws {
        let run = try SelectionFailureRun()
        try await run.failSelection(failure)
        let rig = run.rig
        #expect(rig.notices.map(\.outcome) == [.interrupted])
        #expect(rig.notices.last?.reason != .reauthorizationNeeded)
        #expect(rig.controller.isOn && rig.controller.isListening && rig.controller.reconnect.isPending)
        #expect(rig.capture.stopCount == 0)
        let discarded = rig.capture.discardedCount
        for _ in 0..<10 { try rig.capture.yield(sineBuffer()) }
        #expect(rig.capture.discardedCount == discarded + 10)
        guard rig.controller.isOn else { await rig.close(); return }
        try await waitUntil { await rig.retry.isWaiting() }
        #expect(rig.notices.map(\.outcome) == [.interrupted])
        run.clock.advance(by: .seconds(4))
        rig.wrapReconnect = { $0 }
        try await rig.reconnect()
        #expect(rig.notices.map(\.outcome) == [.interrupted, .applied])
        #expect(rig.controller.isListening && rig.capture.startCount == 1 && rig.makeCalls == 1)
        #expect(rig.permissionCalls == 1 && rig.unexpected.isEmpty)
        #expect(await rig.connector.openCount(for: rig.endpoint.url) == 3)
        #expect(try rig.currentBinding().targetID == rig.target.id)
        #expect(try await rig.socket.sentFrames().allSatisfy { frame in
            if case .control(.setPrivacy(on: false)) = frame.payload { return false }; return true
        })
        await rig.close()
    }

    @Test func selectionFailureCanRecoverBeyondTheFormerDeadline() async throws {
        let run = try SelectionFailureRun()
        try await run.failSelection(.notReady)
        let rig = run.rig
        try await waitUntil { await rig.retry.isWaiting() }
        #expect(rig.controller.reconnect.isPending && rig.controller.isListening)
        run.clock.advance(by: .seconds(5))
        #expect(rig.controller.reconnect.status == "Reconnecting…")
        rig.wrapReconnect = { $0 }
        try await rig.reconnect()
        #expect(rig.notices.map(\.outcome) == [.interrupted, .applied])
        #expect(rig.controller.isOn && rig.controller.isListening && rig.capture.stopCount == 0)
        #expect(rig.store.ambientBinding(host: rig.endpoint.id, targetID: rig.target.id) != nil)
        #expect(try await rig.socket.sentFrames().allSatisfy { frame in
            if case .control(.setPrivacy(on: false)) = frame.payload { return false }; return true
        })
        await rig.close()
    }

    @Test func staleSelectionFailureCannotRetryANewerGeneration() async throws {
        let run = try SelectionFailureRun()
        try await run.failSelection(.notReady)
        let rig = run.rig
        try await waitUntil { await rig.retry.isWaiting() }
        let failed = try #require(rig.store.snapshots[rig.endpoint.id]?.connectionGeneration)
        rig.wrapReconnect = { $0 }
        try await rig.reconnect(selectTarget: false)
        try await waitUntil { try await rig.selectionPing(after: 0) != nil }
        let newer = try #require(rig.store.snapshots[rig.endpoint.id]?.connectionGeneration)
        #expect(newer != failed && rig.controller.reconnect.isPending)
        #expect(await rig.store.retryAmbientTransport(host: rig.endpoint.id, generation: failed) == false)
        #expect(rig.store.snapshots[rig.endpoint.id]?.connectionGeneration == newer)
        #expect(await rig.connector.openCount(for: rig.endpoint.url) == 3)
        #expect(await rig.retry.isWaiting() == false)
        try await rig.select(restoring: true)
        try await rig.feed()
        #expect(rig.notices.map(\.outcome) == [.interrupted, .applied])
        #expect(rig.controller.isListening && rig.capture.startCount == 1)
        await rig.close()
    }
}

enum SelectionTransportFailure: CaseIterable, Sendable { case notReady, networkLost, cancelled }

@MainActor
private final class SelectionFailureRun {
    let rig: AmbientReconnectRig
    let clock = TestInstantClock()
    private let failureGate = SleepGate()

    init() throws { rig = try AmbientReconnectRig() }

    func failSelection(_ failure: SelectionTransportFailure) async throws {
        let clock = clock
        rig.controller.reconnect.now = { clock.now() }
        rig.controller.reconnect.sleep = { _ in throw CancellationError() }
        try await rig.start()
        try await rig.drop()
        let failureGate = failureGate
        rig.wrapReconnect = { SelectionFailSocket(base: $0, gate: failureGate, failure: failure) }
        try await rig.reconnect(selectTarget: false)
        try await waitUntil { await failureGate.isWaiting() }
        #expect(rig.store.snapshots[rig.endpoint.id]?.state == .ready)
        #expect(await rig.retry.isWaiting() == false)
        clock.advance(by: .seconds(55))
        await failureGate.fire()
        try await waitUntil { await MainActor.run { !self.rig.notices.isEmpty } }
    }
}

private actor SelectionFailSocket: WebSocketTransport {
    let base: ScriptedSocket
    let gate: SleepGate
    let failure: SelectionTransportFailure
    private var selecting = false

    init(base: ScriptedSocket, gate: SleepGate, failure: SelectionTransportFailure) {
        self.base = base
        self.gate = gate
        self.failure = failure
    }

    func send(_ data: Data) async throws {
        let frame = try FrameCoding.decode(data)
        if case .control(.select) = frame.payload { selecting = true }
        await base.send(data)
        if selecting, case .control(.ping) = frame.payload {
            selecting = false
            try await gate.sleep(.zero)
            switch failure {
            case .notReady: throw HostConnectionFailure.notReady
            case .networkLost: throw URLError(.networkConnectionLost)
            case .cancelled: throw CancellationError()
            }
        }
    }
    func receive() async throws -> Data { try await base.receive() }
    func close() async { await gate.fire(); await base.close() }
}
