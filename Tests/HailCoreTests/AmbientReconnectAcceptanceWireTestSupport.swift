import Foundation
import HailProtocol
@testable import HailCore

actor AmbientAcceptanceTestWire: WebSocketTransport {
    let base: ScriptedSocket
    private var sentAudio = false
    private var held: CheckedContinuation<Void, Never>?
    private var didHold = false
    private var readTransient = false
    private var processedTransient = false
    private var refusing = false
    init(base: ScriptedSocket) { self.base = base }
    func send(_ data: Data) async throws {
        let frame = try FrameCoding.decode(data)
        if case .audio = frame.payload, refusing {
            throw HostConnectionFailure.remote("not_allowed: ambient busy elsewhere")
        }
        await base.send(data)
        if case .audio = frame.payload { sentAudio = true }
        if case .control(.ping) = frame.payload, sentAudio, !didHold {
            didHold = true
            await withCheckedContinuation { held = $0 }
        }
    }
    func receive() async throws -> Data {
        if readTransient { processedTransient = true }
        let data = try await base.receive()
        if case .control(.error(_, let message, _)) = try FrameCoding.decode(data).payload,
           message == "ambient stopped: listener exited" { readTransient = true }
        return data
    }
    func isHeld() -> Bool { held != nil }
    func transientWasProcessed() -> Bool { processedTransient }
    func refuseAudio() { refusing = true }
    func release() { held?.resume(); held = nil }
    func deliver(_ frames: [ControlPayload]) async throws {
        for frame in frames { try await base.push(frame) }
    }
    func close() async { release(); await base.close() }
}
