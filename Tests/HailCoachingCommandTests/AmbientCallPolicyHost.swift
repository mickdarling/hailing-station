import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailCore
@testable import HailDaemonKit

actor CallPolicyHost: WebSocketTransport {
    let base: CallPolicySocket
    let host: HailHost
    let session: HostSession
    let sink: CallPolicySink
    let sendGate = CallPolicySignal()
    private let inputArrived = CallPolicySignal()
    private var lastAudio: Frame?
    private(set) var firstRefusal: String?
    private(set) var refusals = 0
    private(set) var resumedAttempts = 0

    init(base: CallPolicySocket, host: HailHost, session: HostSession, sink: CallPolicySink) {
        self.base = base
        self.host = host
        self.session = session
        self.sink = sink
    }

    static func make(base: CallPolicySocket, target: String) async throws -> CallPolicyHost {
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
        guard case .audio(let audio) = frame.payload else {
            return
        }
        lastAudio = frame
        if audio.isResume {
            resumedAttempts += 1
        }
        let result = await session.receive(frame)
        for response in result.frames {
            try await base.push(FrameCoding.encode(response))
        }
        if !result.frames.isEmpty {
            if case .control(.error(_, let message, _)) = result.frames.first?.payload {
                firstRefusal = firstRefusal ?? message
            }
            refusals += 1
            try await base.push(.targets([callPolicyBarrier]))
            await inputArrived.fire()
            if refusals == 1 {
                await sendGate.wait()
            }
        } else {
            await inputArrived.fire()
        }
    }

    func refuseRetainedStream() async throws {
        let previous = try #require(lastAudio)
        guard case .audio(let audio) = previous.payload else {
            throw CancellationError()
        }
        let pending = AudioPayload(
            codec: audio.codec, sampleRate: audio.sampleRate, channels: audio.channels,
            sequence: audio.sequence + 1, streamID: audio.streamID, bytes: audio.bytes
        )
        let result = await session.receive(Frame(
            timestamp: 1, target: previous.target, source: "synthetic", payload: .audio(pending)
        ))
        try #require(result.frames.contains {
            if case .control(.error(.notAllowed, let message, _)) = $0.payload {
                return message.hasPrefix("ambient target_policy_changed")
            }
            return false
        })
        for response in result.frames {
            try await base.push(FrameCoding.encode(response))
        }
        try await base.push(.targets([callPolicyBarrier]))
    }

    func awaitInput() async {
        await inputArrived.wait()
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
