import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

extension WebSocketReceivePumpTests {
    @Test func privacyControlRemainsAheadOfLaterAudio() async throws {
        let rig = PumpRig()
        let park = PumpAudioPark()
        let sink = PumpPrivacySink()
        let clock = AmbientTestClock()
        let gate = AmbientAudioGate(target: "tmux:a", sink: sink, sweepInterval: nil, clock: { clock.now })
        let session = try await pumpPrivacySession(gate)
        let stream = UUID()
        let start = try FrameCoding.decode(pumpAudio(stream, 0))
        #expect(await session.receive(start).frames.isEmpty)
        defer { park.release.finish(.success(())); rig.pump.stop() }
        rig.start { frame in
            guard let frame else { Issue.record("expected frame"); return }
            if case .control(.ping) = frame.payload { await park.wait(); return }
            clock.advance(.milliseconds(100))
            let result = await session.receive(frame)
            #expect(result.frames.isEmpty)
        }
        rig.transport.deliver(.application(try pumpMarker(1)))
        try await park.entered.wait("privacy dispatch parked")
        let worker = try #require(rig.pump.worker)
        for sequence in 1...10 { rig.transport.deliver(.application(try pumpAudio(stream, sequence))) }
        let privacy = sessionFrame(payload: .control(.setPrivacy(on: true)))
        let input = sessionFrame(payload: .control(.ambientInput(route: "built_in_mic")))
        rig.transport.deliver(.application(try FrameCoding.encode(privacy)))
        rig.transport.deliver(.application(try FrameCoding.encode(input)))
        for sequence in 11...45 {
            rig.transport.deliver(.application(try pumpAudio(stream, sequence, final: sequence == 45)))
        }
        #expect(sink.calls == ["audio:0"])
        #expect(rig.pump.droppedAudioCount == 14)
        park.release.finish(.success(()))
        await worker.value
        let controls = ["audio:0", "privacy:true", "input:built_in_mic"]
        let audio = (15...45).map { "audio:\($0)" }
        #expect(sink.calls == controls + audio)
        #expect(!rig.lifecycle.isRetired)
    }
}

private final class PumpPrivacySink: AmbientAudioSink {
    private let recorded = Mutex<[String]>([])
    var calls: [String] { recorded.withLock { $0 } }
    func ambientAudio(_ event: AmbientAudioEvent) {
        if case .segment(_, let sequence, _) = event { recorded.withLock { $0.append("audio:\(sequence)") } }
    }
    func ambientPrivacy(_ on: Bool, connection: UUID) { recorded.withLock { $0.append("privacy:\(on)") } }
    func ambientInputRoute(_ route: String, connection: UUID) { recorded.withLock { $0.append("input:\(route)") } }
}

private func pumpPrivacySession(_ gate: AmbientAudioGate) async throws -> HostSession {
    var policy = Policy()
    try policy.allow("tmux:a", binding: "binding-a", tier: .open)
    let targets = [AdapterTarget(name: "a", binding: "binding-a")]
    let (host, _) = try await sessionHost(targets: targets, policy: policy)
    let session = HostSession(host: host, authorizer: PersonalTerminalAuthorizer(ambientAudio: gate))
    _ = await session.receive(helloFrame())
    _ = await session.receive(sessionFrame(payload: .control(.select(targetID: "tmux:a"))))
    return session
}
