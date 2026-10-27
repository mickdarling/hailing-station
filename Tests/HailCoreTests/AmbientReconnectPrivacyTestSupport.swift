import Foundation
import HailProtocol
import Testing
@testable import HailCore

/// A synthetic future pre-arm/park host or today's silent host. Confirmation is explicitly released by the test.
actor AmbientPrivacyHost: WebSocketTransport {
    enum Response: Sendable { case confirm, silent, refuse, requestRefusal, off, expired, sendFailure }
    let base: ScriptedSocket
    let response: Response
    private var requested = false
    private var confirmed = false
    private var prematureAudio = 0
    init(base: ScriptedSocket, response: Response = .confirm) {
        self.base = base
        self.response = response
    }
    func send(_ data: Data) async throws {
        let frame = try FrameCoding.decode(data)
        if case .control(.setPrivacy(on: true)) = frame.payload {
            requested = true
            if response == .sendFailure { throw SocketTestError.closed }
        }
        if case .audio = frame.payload, !confirmed { prematureAudio += 1 }
        await base.send(data)
    }
    func answer() async throws {
        #expect(requested)
        switch response {
        case .confirm:
            confirmed = true
            try await base.push(.duckMode(on: true, reason: "device"))
        case .off: try await base.push(.duckMode(on: false, reason: "device"))
        case .expired: try await base.push(.duckMode(on: true, reason: "device", expires: 1))
        case .requestRefusal:
            try await base.push(.error(code: .voiceRouteRefused, message: "synthetic request refusal"))
        case .refuse: try await base.push(.error(code: .notAllowed, message: "synthetic privacy refusal"))
        case .silent, .sendFailure: break
        }
    }
    func receivedRequest() -> Bool { requested }
    func audioBeforeConfirmation() -> Int { prematureAudio }
    func receive() async throws -> Data { try await base.receive() }
    func close() async { await base.close() }
}

@MainActor
extension AmbientReconnectRig {
    func confirmInitialPrivacy() async throws {
        try await store.setPrivacy(on: true, host: endpoint.id)
        try await socket.push(.duckMode(on: true, reason: "device"))
        try await waitUntil { await MainActor.run {
            self.store.privacySwitch(self.endpoint.id).isPrivate
                && self.store.privacyLocal[self.endpoint.id]?.request == nil
        } }
    }
    func privateReconnect(response: AmbientPrivacyHost.Response = .confirm,
                          parked: Bool = false) async throws -> AmbientPrivacyHost {
        let base = ScriptedSocket()
        let host = AmbientPrivacyHost(base: base, response: response)
        wrapReconnect = { _ in host }
        // Reuse the rig's handshake and automatic target-confirmation on the fake host socket.
        socket = base
        await connector.enqueue(.socket(host), for: endpoint.url)
        await retry.fire()
        try await handshake(base, mode: parked ? .duckMode(on: true) : nil)
        try await confirmAutomaticSelection()
        try await waitUntil { await host.receivedRequest() }
        return host
    }
    func expectNoRestoredPCM() async throws {
        #expect(try await socket.sentFrames().allSatisfy { if case .audio = $0.payload {
            return false
        }; return true })
    }
    func discardWhileWaiting() throws {
        let discarded = capture.discardedCount
        for _ in 0..<20 { try capture.yield(sineBuffer()) }
        #expect(capture.discardedCount == discarded + 20)
    }
}
