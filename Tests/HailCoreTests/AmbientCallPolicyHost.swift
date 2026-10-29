import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailCore
@testable import HailDaemonKit

actor CallPolicyHost: WebSocketTransport {
    let base: ScriptedSocket
    let host: HailHost
    let session: HostSession
    let sink: CallPolicySink
    let sendGate = SleepGate()
    private(set) var refusals = 0
    private(set) var resumedAttempts = 0

    init(base: ScriptedSocket, host: HailHost, session: HostSession, sink: CallPolicySink) {
        self.base = base
        self.host = host
        self.session = session
        self.sink = sink
    }

    static func make(base: ScriptedSocket, target: String) async throws -> CallPolicyHost {
        let registry = Registry()
        try await registry.register(CallPolicyAdapter())
        var policy = Policy()
        try policy.allow(target, binding: "synthetic-binding", tier: .open)
        let host = try HailHost(registry: registry, store: CallPolicyStore(policy))
        let sink = CallPolicySink()
        let instant = ContinuousClock.now
        let gate = AmbientAudioGate(target: target, sink: sink, sweepInterval: nil, clock: { instant })
        let session = HostSession(host: host, authorizer: PersonalTerminalAuthorizer(ambientAudio: gate))
        _ = await session.receive(Frame(timestamp: 1, source: "synthetic", payload: .control(.hello(HelloInfo(
            versions: [ProtocolVersion.current], capabilities: ["stream_audio", "select_target"],
            deviceName: "Synthetic"
        )))))
        let selected = await session.receive(Frame(timestamp: 1, source: "synthetic",
                                                  payload: .control(.select(targetID: target))))
        try #require(selected.frames.isEmpty)
        return CallPolicyHost(base: base, host: host, session: session, sink: sink)
    }

    func send(_ data: Data) async throws {
        let frame = try FrameCoding.decode(data)
        await base.send(data)
        guard case .audio(let audio) = frame.payload else { return }
        if audio.isResume {
            resumedAttempts += 1
        }
        let result = await session.receive(frame)
        for response in result.frames {
            try await base.push(FrameCoding.encode(response))
        }
        if !result.frames.isEmpty {
            refusals += 1
            try await base.push(.targets([callPolicyBarrier]))
            if refusals == 1 {
                try await sendGate.sleep(.zero)
            }
        }
    }

    func receive() async throws -> Data {
        try await base.receive()
    }

    func close() async {
        await base.close()
    }
}

final class CallPolicySink: AmbientAudioSink {
    private let segments = Mutex(0)
    var segmentCount: Int { segments.withLock { $0 } }

    func ambientAudio(_ event: AmbientAudioEvent) {
        if case .segment = event {
            segments.withLock { $0 += 1 }
        }
    }
}
