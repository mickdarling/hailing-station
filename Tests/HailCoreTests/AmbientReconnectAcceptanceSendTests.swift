import Foundation
import HailProtocol
import Testing
@testable import HailCore

@MainActor
@Suite(.serialized) struct AmbientReconnectAcceptanceSendTests {
    @Test func sendRefusalAfterAcceptancePongUsesOrdinaryStopPathWhileWaiterIsHeld() async throws {
        let rig = try AmbientReconnectRig()
        try await rig.start()
        try await rig.drop()
        let socket = ScriptedSocket()
        let transport = HeldAcceptancePingSocket(base: socket)
        rig.socket = socket
        await rig.connector.enqueue(.socket(transport), for: rig.endpoint.url)
        await rig.retry.fire()
        try await rig.handshake(socket)
        try await rig.select(restoring: true)
        try await rig.feed()
        let id = rig.controller.reconnect.notice?.id
        let nonce = try await rig.waitForAcceptancePing()
        try await waitUntil { await transport.ping.isWaiting() }
        try await socket.push(.pong(nonce: nonce))
        try await waitUntil { await transport.pongWasProcessed() }
        #expect(rig.controller.reconnect.acceptance != nil) // The confirmation sender is still held.
        await transport.refuseAudio()
        try await rig.feed()
        try await waitUntil { await MainActor.run { !rig.controller.isOn && rig.released == 1 } }
        #expect(rig.notices.map(\.id) == [id])
        #expect(!rig.controller.reconnect.replacedAppliedNotice)
        #expect(rig.unexpected.count == 1 && rig.unexpected.first?.contains("ambient busy elsewhere") == true)
        await transport.ping.fire()
        await rig.close()
    }
}

private actor HeldAcceptancePingSocket: WebSocketTransport {
    let base: ScriptedSocket
    let ping = SleepGate()
    private var sentAudio = false
    private var heldNonce: String?
    private var readPong = false
    private var processedPong = false
    private var refusing = false
    init(base: ScriptedSocket) { self.base = base }

    func send(_ data: Data) async throws {
        let frame = try FrameCoding.decode(data)
        if case .audio = frame.payload {
            sentAudio = true
            if refusing { throw HostConnectionFailure.remote("not_allowed: ambient busy elsewhere") }
        }
        await base.send(data)
        if case .control(.ping(let nonce)) = frame.payload, sentAudio {
            heldNonce = nonce
            try await ping.sleep(.zero)
        }
    }

    func receive() async throws -> Data {
        if readPong { processedPong = true } // The ordered receive loop finished the preceding pong callback.
        let data = try await base.receive()
        if case .control(.pong(let nonce)) = try FrameCoding.decode(data).payload, nonce == heldNonce {
            readPong = true
        }
        return data
    }
    func pongWasProcessed() -> Bool { processedPong }
    func refuseAudio() { refusing = true }
    func close() async { await base.close() }
}
