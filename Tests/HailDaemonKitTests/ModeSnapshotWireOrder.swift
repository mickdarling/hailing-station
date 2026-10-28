#if os(macOS)
import Foundation
import Network
import Synchronization

/// Counts complete outbound WebSocket frames below the production peer, alongside its inbound processing.
final class ModeSnapshotWireOrder: Sendable {
    private struct State {
        var armed = false
        var frames = 0
        var bytes = Data()
        var observed: [String] = []
        var early: [String] = []
    }
    private let state = Mutex(State())
    var observed: [String] { state.withLock { $0.observed } }
    var early: [String] { state.withLock { $0.early } }

    func arm() { state.withLock { $0 = State(armed: true) } }
    func observe(_ event: String) {
        state.withLock {
            $0.observed.append(event)
            if $0.frames < 3 { $0.early.append(event) }
        }
    }

    func forwarded(_ data: Data) {
        state.withLock { state in
            // Upgrade bytes pass before arm(); only framed WebSocket output is counted afterward.
            guard state.armed else { return }
            state.bytes.append(data)
            while let length = Self.frameLength(state.bytes), state.bytes.count >= length {
                state.frames += 1
                state.bytes.removeFirst(length)
            }
        }
    }

    private static func frameLength(_ data: Data) -> Int? {
        let bytes = Array(data)
        guard bytes.count >= 2 else { return nil }
        let size = Int(bytes[1] & 0x7f)
        var header = 2, length = size
        if size == 126 {
            guard bytes.count >= 4 else { return nil }
            header = 4
            length = Int(bytes[2]) * 256 + Int(bytes[3])
        } else if size == 127 {
            guard bytes.count >= 10 else { return nil }
            header = 10
            length = bytes[2..<10].reduce(0) { $0 * 256 + Int($1) }
        }
        return header + (bytes[1] & 0x80 == 0 ? 0 : 4) + length
    }
}

/// This framer is installed only by the synthetic ordering rig, never by the production listener.
final class ModeSnapshotObservingFramer: NWProtocolFramerImplementation {
    static let label = "mode-snapshot-test-order"
    private let order: ModeSnapshotWireOrder
    init(framer: NWProtocolFramer.Instance) {
        order = framer.options["order"] as? ModeSnapshotWireOrder ?? ModeSnapshotWireOrder()
    }
    func start(framer: NWProtocolFramer.Instance) -> NWProtocolFramer.StartResult {
        framer.passThroughInput()
        return .ready
    }
    func stop(framer: NWProtocolFramer.Instance) -> Bool { true }
    func cleanup(framer: NWProtocolFramer.Instance) {}
    func wakeup(framer: NWProtocolFramer.Instance) {}

    func handleInput(framer: NWProtocolFramer.Instance) -> Int { 0 }

    func handleOutput(framer: NWProtocolFramer.Instance, message: NWProtocolFramer.Message,
                      messageLength: Int, isComplete: Bool) {
        var bytes = Data()
        _ = framer.parseOutput(minimumIncompleteLength: messageLength, maximumLength: messageLength) { buffer, _ in
            if let buffer { bytes = Data(buffer) }
            return 0
        }
        do {
            try framer.writeOutputNoCopy(length: messageLength)
            order.forwarded(bytes)
        } catch { framer.markFailed(error: .posix(.EIO)) }
    }
}
#endif
