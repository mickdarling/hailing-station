#if os(macOS)
import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

extension AmbientGapFillTests {
    @Test func hostPumpEvictionAndPhoneHoleReachRightyoWithIdenticalSilence() async throws {
        let host = try await AmbientGapFillRig.make()
        let phone = try await AmbientGapFillRig.make()
        let pump = PumpRig()
        let park = PumpAudioPark()
        let session = Mutex<String?>(nil)
        defer { park.release.finish(.success(())); pump.pump.stop() }
        do {
            let stream = UUID()
            pump.start { frame in
                guard let frame else { Issue.record("expected frame"); return }
                guard case .audio(let audio) = frame.payload else { await park.wait(); return }
                if audio.sequence == 6 { host.clock.advance(.seconds(1)) }
                #expect(await host.env.gate.admit(audio, connection: host.connection,
                                                  target: RecipientTestRig.target) == nil)
                if audio.sequence == 0 {
                    session.withLock { $0 = host.env.router.activePipeline?.session }
                }
            }
            pump.transport.deliver(.application(try pumpMarker(1)))
            try await park.entered.wait("gap-fill dispatch parked")
            let worker = try #require(pump.pump.worker)
            try Self.deliverBurst(to: pump, stream: stream)
            #expect(pump.pump.droppedAudioCount == 5)
            #expect(session.withLock { $0 } == nil)
            park.release.finish(.success(()))
            await worker.value
            await host.env.router.settle()
            let hostSession = try #require(session.withLock { $0 })
            try await Self.verifyParity(host: host, phone: phone, session: hostSession, stream: stream)
            #expect(pump.transport.maximumOutstanding == 1)
        } catch {
            park.release.finish(.success(())); pump.pump.stop()
            await host.finish(); await phone.finish()
            throw error
        }
        await host.finish(); await phone.finish()
    }

    private static func verifyParity(host: AmbientGapFillRig, phone: AmbientGapFillRig,
                                     session: String, stream: UUID) async throws {
        let hostBytes = try host.heard(session)
        try await phone.send(stream, 0)
        let phoneSession = try #require(phone.env.router.activePipeline?.session)
        phone.clock.advance(.seconds(1))
        // Exactly the same hole already present at ingress, as with the phone's oldest-non-final drop.
        for sequence in 6...36 { try await phone.send(stream, sequence, final: sequence == 36) }
        await phone.env.router.settle()
        let expected = Self.expectedPumpPCM()
        #expect(hostBytes == expected)
        #expect(try phone.heard(phoneSession) == expected)
        #expect(hostBytes.count == 37 * 3_200)
        #expect(host.fills.map(\.detail) == ["fills=1 missing=5 filled_ms=500 capped=0"])
        #expect(phone.fills.map(\.detail) == host.fills.map(\.detail))
    }

    private static func deliverBurst(to pump: PumpRig, stream: UUID) throws {
        for sequence in 0...36 {
            let audio = AmbientGapFillRig.segment(stream, sequence, final: sequence == 36)
            let frame = sessionFrame(target: RecipientTestRig.target, payload: .audio(audio))
            pump.transport.deliver(.application(try FrameCoding.encode(frame)))
        }
    }

    private static func expectedPumpPCM() -> Data {
        var expected = AmbientGapFillRig.chunk(0) + AmbientGapFillRig.silence(5)
        for sequence in 6...36 { expected.append(AmbientGapFillRig.chunk(sequence)) }
        return expected
    }

    @Test func refusedAndReplyAudioNeverStartAChildOrFill() async throws {
        let rig = try await AmbientGapFillRig.make()
        var refused = AmbientGapFillRig.segment(UUID(), 100)
        #expect(await rig.env.gate.admit(refused, frameTarget: "other", selectedTarget: "other",
                                         connection: rig.connection) != nil)
        refused.reply = ReplyDescriptor(id: UUID(), hostID: "synthetic", targetID: "synthetic",
                                        audioStreamID: UUID())
        #expect(await rig.env.gate.admit(refused, connection: rig.connection,
                                         target: RecipientTestRig.target) != nil)
        #expect(rig.env.router.activePipeline == nil && rig.env.router.liveRuns == 0)
        #expect(rig.fills.isEmpty)
        await rig.finish()
    }
}
#endif
