import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

extension WebSocketReceivePumpTests {
    @Test func onlyOneSessionReceiveRunsWhileAuthorizationIsSuspended() async throws {
        let entered = SelectionPreflightSignal<Void>()
        let release = SelectionPreflightSignal<Void>()
        let completed = SelectionPreflightSignal<Void>()
        let (host, _) = try await sessionHost()
        let session = HostSession(host: host, authorizer: PumpSessionAuthorizer(entered: entered, release: release))
        _ = await session.receive(helloFrame())
        let rig = PumpRig()
        let observations = Mutex((active: 0, peak: 0, replies: [ControlPayload]()))
        defer { release.finish(.success(())); rig.pump.stop() }
        rig.start { data in
            observations.withLock { state in
                state.active += 1
                state.peak = max(state.peak, state.active)
            }
            let result = await session.receive(data)
            observations.withLock { state in
                state.active -= 1
                for frame in result.frames {
                    if case .control(let control) = frame.payload { state.replies.append(control) }
                }
                if state.replies.count == 2 { completed.finish(.success(())) }
            }
        }
        let first = sessionFrame(payload: .control(.ping(nonce: "first")))
        let second = sessionFrame(payload: .control(.ping(nonce: "second")))
        rig.transport.deliver(.application(try FrameCoding.encode(first)))
        try await entered.wait("session receive in authorization")
        let worker = try #require(rig.pump.worker)
        rig.transport.deliver(.application(try FrameCoding.encode(second)))
        rig.transport.deliver(.control)
        #expect(observations.withLock { $0.active } == 1)
        #expect(observations.withLock { $0.replies.isEmpty })
        #expect(rig.transport.outstanding == 1)
        release.finish(.success(()))
        try await completed.wait("session receive responses")
        await worker.value
        #expect(observations.withLock { $0.peak } == 1)
        #expect(observations.withLock { $0.active } == 0)
        #expect(observations.withLock { $0.replies } == [.pong(nonce: "first"), .pong(nonce: "second")])
        #expect(rig.transport.maximumOutstanding == 1)
    }
}

private struct PumpSessionAuthorizer: HostSessionAuthorizing {
    let capabilities = ["ping"]
    let entered: SelectionPreflightSignal<Void>
    let release: SelectionPreflightSignal<Void>

    func authorize(_ frame: Frame) async -> HostSessionAuthorization {
        if case .control(.ping(nonce: "first")) = frame.payload {
            entered.finish(.success(()))
            _ = try? await release.wait("session authorization release")
        }
        return .allow
    }
}
