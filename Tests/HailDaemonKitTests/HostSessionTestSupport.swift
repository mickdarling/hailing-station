import Foundation
import HailProtocol
@testable import HailDaemonKit

func sessionFrame(version: Int = 1, target: String? = nil, payload: FramePayload) -> Frame {
    Frame(
        version: version, timestamp: 1_700_000_000_000, target: target, source: "terminal", payload: payload
    )
}

func sessionHost(
    targets: [AdapterTarget] = [], policy: Policy = Policy()
) async throws -> (HailHost, FakeAdapter) {
    let adapter = FakeAdapter(kind: "tmux", targets: targets)
    let registry = Registry()
    try await registry.register(adapter)
    let host = try HailHost(registry: registry, store: InMemoryPolicyStore(policy))
    return (host, adapter)
}

func helloFrame(versions: [Int] = [1], envelopeVersion: Int = 1) -> Frame {
    sessionFrame(
        version: envelopeVersion,
        payload: .control(.hello(HelloInfo(versions: versions, capabilities: ["probe"], deviceName: "test")))
    )
}

func onlyControl(_ result: HostSessionResult) throws -> ControlPayload {
    guard result.frames.count == 1, case .control(let control) = result.frames[0].payload else {
        throw TestSupportError.expectedOneControl
    }
    return control
}

enum TestSupportError: Error {
    case expectedOneControl
}
