import Foundation
import HailProtocol
import Testing
@testable import HailCore

@MainActor
final class AmbientRefusalOrderRun {
    let rig: AmbientReconnectRig
    let base = ScriptedSocket()
    let ping = SleepGate()
    let closing: AmbientClosingSocket
    let clock = TestInstantClock()
    let message = "retained selection requires owner authorization"

    init() throws {
        rig = try AmbientReconnectRig()
        closing = AmbientClosingSocket(base: base)
    }

    func startSelection(sendError: RefusalPingSendError? = nil) async throws -> Task<Void, any Error> {
        let clock = clock
        rig.controller.reconnect.now = { clock.now() }
        rig.controller.reconnect.sleep = { _ in throw CancellationError() }
        try await rig.start()
        var refreshed = rig.endpoint
        refreshed.name = "Refreshed owner-authorized host"
        rig.socket = base
        let held = AmbientHeldSelectionPing(base: closing, gate: ping, sendError: sendError)
        await rig.connector.enqueue(.socket(held), for: refreshed.url)
        await rig.store.upsert(refreshed)
        try await handshakeWithoutAutomaticSelection()
        let rig = rig
        // Own the same restoring select as the automatic task, so both its result and completion are observable.
        let selection = Task {
            try await rig.store.selectTarget(host: rig.endpoint.id, targetID: rig.target.id, restoring: true)
        }
        try await waitUntil { await self.ping.isWaiting() }
        try rig.discardWhileWaiting()
        return selection
    }

    private func handshakeWithoutAutomaticSelection() async throws {
        rig.store.ambientController = nil
        defer { rig.store.ambientController = rig.controller }
        try await rig.handshake(base)
    }

    func refuse() async throws {
        try await base.push(.error(code: .unauthorized, message: message))
        try await waitUntil { await self.closing.gate.isWaiting() }
        #expect(rig.store.snapshots[rig.endpoint.id]?.state == .ready)
        #expect(await ping.isWaiting())
    }

    func publishFailure() async throws {
        await closing.gate.fire()
        try await waitUntil { await MainActor.run {
            if case .failed = self.rig.store.snapshots[self.rig.endpoint.id]?.state { return true }; return false
        } }
    }

    func expectTerminalRefusal(_ result: Result<Void, any Error>) {
        if case .failure(let error) = result {
            #expect(error as? HostConnectionFailure == .remote("unauthorized: \(message)"))
        } else { Issue.record("A terminal authorization refusal must reject its selection") }
    }

    func settleStopIfRequested() async throws {
        if !rig.controller.isListening {
            try await waitUntil { await MainActor.run { !self.rig.controller.isOn && self.rig.released == 1 } }
        }
    }

    func expectOwnerNotice() throws {
        let notice = try #require(rig.notices.first)
        #expect(rig.notices.count == 1 && notice.outcome == .blocked)
        #expect(notice.reason == .reauthorizationNeeded)
        #expect(notice.reason?.diagnosticToken == "reauthorization_needed")
        #expect(notice.text == "Listening stopped; re-authorization needed. Choose a destination to continue.")
        #expect(rig.appPresentation.noticeAction == .selectDestination)
        #expect(!rig.controller.isListening && rig.unexpected.isEmpty)
    }

    func expectNoPCMOrPrivacyOff() async throws {
        #expect(try await audioFrames(base).isEmpty)
        #expect(try await base.sentFrames().allSatisfy { frame in
            if case .control(.setPrivacy(on: false)) = frame.payload { return false }; return true
        })
    }
}

actor AmbientHeldSelectionPing: WebSocketTransport {
    let base: any WebSocketTransport
    let gate: SleepGate
    let sendError: RefusalPingSendError?
    private var selecting = false
    init(base: any WebSocketTransport, gate: SleepGate, sendError: RefusalPingSendError?) {
        self.base = base; self.gate = gate; self.sendError = sendError
    }
    func send(_ data: Data) async throws {
        let frame = try FrameCoding.decode(data)
        if case .control(.select) = frame.payload { selecting = true }
        try await base.send(data)
        if selecting, case .control(.ping) = frame.payload {
            selecting = false
            try await gate.sleep(.zero)
            try sendError?.fail()
        }
    }
    func receive() async throws -> Data { try await base.receive() }
    func close() async { await base.close() }
}

enum RefusalPingSendError: CaseIterable, Sendable {
    case cancellation, urlCancellation
    func fail() throws {
        switch self {
        case .cancellation: throw CancellationError()
        case .urlCancellation: throw URLError(.cancelled)
        }
    }
}
