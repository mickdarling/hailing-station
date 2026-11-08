import Foundation
import HailProtocol
import Network
import Synchronization
import Testing
@testable import HailDaemonKit

@Suite(.timeLimit(.minutes(1))) struct WebSocketReceivePumpTests {
    @Test func oneWorkerDrainsInOrderWhileReceivingControls() async throws {
        let rig = PumpRig()
        let entered = SelectionPreflightSignal<Void>()
        let release = SelectionPreflightSignal<Void>()
        let completed = SelectionPreflightSignal<Void>()
        let observations = Mutex((active: 0, peak: 0, values: [UInt8]()))
        defer { release.finish(.success(())); rig.pump.stop() }
        rig.start { data in
            observations.withLock { state in
                state.active += 1
                state.peak = max(state.peak, state.active)
                state.values.append(data[0])
            }
            if data[0] == 1 {
                entered.finish(.success(()))
                _ = try? await release.wait("worker release")
            }
            observations.withLock { $0.active -= 1 }
            if data[0] == 3 { completed.finish(.success(())) }
        }
        rig.transport.deliver(.application(Data([1])))
        try await entered.wait("first application entry")
        let worker = try #require(rig.pump.worker)
        rig.transport.deliver(.application(Data([2])))
        rig.transport.deliver(.control)
        rig.transport.deliver(.control)
        rig.transport.deliver(.application(Data([3])))
        #expect(rig.transport.outstanding == 1)
        #expect(observations.withLock { $0.values } == [1])
        release.finish(.success(()))
        try await completed.wait("ordered completion")
        await worker.value
        #expect(observations.withLock { $0.values } == [1, 2, 3])
        #expect(observations.withLock { $0.peak } == 1)
        #expect(rig.transport.maximumOutstanding == 1)
        #expect(rig.transport.receives == 6)
    }

    @Test(arguments: [false, true])
    func overflowTerminatesWithTheWorkerParked(bytes: Bool) async throws {
        let rig = PumpRig()
        let entered = SelectionPreflightSignal<Void>()
        let release = SelectionPreflightSignal<Void>()
        let processed = Mutex(0)
        defer { release.finish(.success(())); rig.pump.stop() }
        rig.start { _ in
            processed.withLock { $0 += 1 }
            entered.finish(.success(()))
            _ = try? await release.wait("overflow worker release")
        }
        rig.transport.deliver(.application(Data([1])))
        try await entered.wait("overflow active message")
        let worker = try #require(rig.pump.worker)
        let size = bytes ? PayloadLimits.defaultMaxFrameBytes : 1
        let count = bytes ? 2 : 8
        for _ in 0..<count { rig.transport.deliver(.application(Data(repeating: 0, count: size))) }
        #expect(!rig.lifecycle.isRetired)
        #expect(rig.transport.outstanding == 1)
        rig.transport.deliver(.application(Data([0])))
        #expect(rig.lifecycle.isRetired)
        #expect(try await rig.ended.wait("overflow termination") == "receive queue limit")
        #expect(rig.transport.outstanding == 0)
        let receives = rig.transport.receives
        release.finish(.success(()))
        await worker.value
        #expect(processed.withLock { $0 } == 1)
        #expect(rig.transport.receives == receives)
        #expect(rig.transport.maximumOutstanding == 1)
    }

    @Test(arguments: [false, true])
    func retirementClearsQueuedMessagesBeforeWorkerRelease(transportClose: Bool) async throws {
        let rig = PumpRig()
        let entered = SelectionPreflightSignal<Void>()
        let release = SelectionPreflightSignal<Void>()
        let processed = Mutex(0)
        defer { release.finish(.success(())); rig.pump.stop() }
        rig.start { _ in
            processed.withLock { $0 += 1 }
            entered.finish(.success(()))
            _ = try? await release.wait("retired worker release")
        }
        rig.transport.deliver(.application(Data([1])))
        try await entered.wait("retired active message")
        let worker = try #require(rig.pump.worker)
        rig.transport.deliver(.application(Data([2])))
        if transportClose {
            rig.transport.deliver(.terminal("peer closed"))
            #expect(try await rig.ended.wait("close observed") == "peer closed")
        } else {
            rig.lifecycle.retire()
            // The one already outstanding receive may still complete after local retirement.
            rig.transport.deliver(.control)
        }
        #expect(rig.lifecycle.isRetired)
        let receives = rig.transport.receives
        release.finish(.success(()))
        await worker.value
        #expect(processed.withLock { $0 } == 1)
        #expect(rig.transport.receives == receives)
    }

    @Test func classificationRetiresMalformedAndFailedReceives() async throws {
        let close = NWProtocolWebSocket.Metadata(opcode: .close)
        let closeContext = NWConnection.ContentContext(identifier: "test.close", metadata: [close])
        let text = NWProtocolWebSocket.Metadata(opcode: .text)
        let textContext = NWConnection.ContentContext(identifier: "test.text", metadata: [text])
        let events: [WebSocketIngressPump.Event] = [
            .terminal("peer closed"),
            WebSocketIngressPump.classify(nil, context: closeContext, error: nil),
            WebSocketIngressPump.classify(Data(), context: nil, error: nil),
            WebSocketIngressPump.classify(nil, context: textContext, error: nil),
            WebSocketIngressPump.classify(nil, context: textContext, error: .posix(.ECONNRESET))
        ]
        for event in events {
            let rig = PumpRig()
            rig.start { _ in Issue.record("terminal metadata must not reach application processing") }
            rig.transport.deliver(event)
            #expect(rig.lifecycle.isRetired)
            _ = try await rig.ended.wait("classified termination")
            #expect(rig.transport.receives == 1)
        }
    }
}

private final class PumpTransport: Sendable {
    private struct State {
        var callback: (@Sendable (WebSocketIngressPump.Event) -> Void)?
        var receives = 0
        var maximum = 0
    }
    private let state = Mutex(State())
    var receives: Int { state.withLock { $0.receives } }
    var outstanding: Int { state.withLock { $0.callback == nil ? 0 : 1 } }
    var maximumOutstanding: Int { state.withLock { $0.maximum } }

    func receive(_ callback: @escaping @Sendable (WebSocketIngressPump.Event) -> Void) {
        state.withLock { state in
            #expect(state.callback == nil)
            state.maximum = max(state.maximum, state.callback == nil ? 1 : 2)
            state.callback = callback
            state.receives += 1
        }
    }
    func deliver(_ event: WebSocketIngressPump.Event) {
        let callback = state.withLock { state in
            defer { state.callback = nil }
            return state.callback
        }
        #expect(callback != nil)
        callback?(event)
    }
}

private struct PumpRig {
    let transport = PumpTransport()
    let lifecycle = ReplyTransportLifecycle()
    let ended = SelectionPreflightSignal<String>()
    let pump: WebSocketIngressPump

    init() {
        let transport = transport
        pump = WebSocketIngressPump(lifecycle: lifecycle, receive: { transport.receive($0) })
    }
    func start(_ process: @escaping WebSocketIngressPump.Process) {
        let ended = ended
        pump.start(process: process, onEnd: { ended.finish(.success($0)) })
    }
}
