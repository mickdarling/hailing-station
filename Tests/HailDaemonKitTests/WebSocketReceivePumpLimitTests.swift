import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

extension WebSocketReceivePumpTests {
    @Test func aggregateByteCapTerminatesBeforeAnyEviction() async throws {
        let rig = PumpRig()
        let park = PumpAudioPark()
        defer { park.release.finish(.success(())); rig.pump.stop() }
        rig.start { _ in await park.wait() }
        rig.transport.deliver(.application(try pumpMarker(1)))
        try await park.entered.wait("byte cap dispatch parked")
        let worker = try #require(rig.pump.worker)
        for _ in 0..<2 {
            rig.transport.deliver(.application(Data(repeating: 32, count: PayloadLimits.defaultMaxFrameBytes)))
        }
        let stream = UUID()
        for sequence in 1...30 {
            var data = try pumpAudio(stream, sequence)
            data.append(Data(repeating: 32, count: PayloadLimits.defaultMaxFrameBytes - data.count))
            rig.transport.deliver(.application(data))
        }
        #expect(!rig.lifecycle.isRetired)
        #expect(rig.pump.droppedAudioCount == 0)
        rig.transport.deliver(.application(try pumpAudio(stream, 31)))
        #expect(rig.lifecycle.isRetired)
        #expect(try await rig.ended.wait("aggregate cap termination") == "receive queue limit")
        #expect(rig.pump.droppedAudioCount == 0)
        park.release.finish(.success(()))
        await worker.value
    }

    @Test(arguments: [false, true])
    func unclassifiableFramesUseNonDroppableBound(malformed: Bool) async throws {
        let rig = PumpRig()
        let park = PumpAudioPark()
        defer { park.release.finish(.success(())); rig.pump.stop() }
        rig.start { _ in await park.wait() }
        rig.transport.deliver(.application(try pumpMarker(1)))
        try await park.entered.wait("fail closed dispatch parked")
        let worker = try #require(rig.pump.worker)
        let unknown = sessionFrame(payload: .unknown(type: "future", payload: .null))
        let data = malformed ? Data("{\"type\":\"audio\"}".utf8) : try FrameCoding.encode(unknown)
        for _ in 0..<8 { rig.transport.deliver(.application(data)) }
        #expect(!rig.lifecycle.isRetired)
        rig.transport.deliver(.application(data))
        #expect(rig.lifecycle.isRetired)
        #expect(rig.pump.droppedAudioCount == 0)
        park.release.finish(.success(()))
        await worker.value
    }

    @Test func singleOversizedMessageTerminates() async throws {
        let rig = PumpRig()
        rig.start { _ in Issue.record("oversized message must not reach worker") }
        rig.transport.deliver(.application(Data(count: PayloadLimits.defaultMaxFrameBytes + 1)))
        #expect(rig.lifecycle.isRetired)
        #expect(try await rig.ended.wait("oversized termination") == "receive queue limit")
        #expect(rig.transport.receives == 1)
    }
    @Test func protectedAudioKeepsItsPositionDuringLaterPressure() async throws {
        let rig = PumpRig()
        let park = PumpAudioPark()
        let first = UUID()
        let second = UUID()
        let delivered = Mutex<[String]>([])
        defer { park.release.finish(.success(())); rig.pump.stop() }
        rig.start { frame in
            guard let frame, case .audio(let audio) = frame.payload else { await park.wait(); return }
            let stream = audio.streamID == first ? "first" : "second"
            delivered.withLock { $0.append("\(stream):\(audio.sequence)") }
        }
        rig.transport.deliver(.application(try pumpMarker(1)))
        try await park.entered.wait("protected audio dispatch parked")
        let worker = try #require(rig.pump.worker)
        for sequence in 0...31 {
            rig.transport.deliver(.application(try pumpAudio(first, sequence, final: sequence == 31)))
        }
        for sequence in 0...35 { rig.transport.deliver(.application(try pumpAudio(second, sequence))) }
        #expect(!rig.lifecycle.isRetired)
        #expect(rig.pump.droppedAudioCount == 36)
        park.release.finish(.success(()))
        await worker.value
        let startsAndFinal = ["first:0", "first:31", "second:0"]
        let newest = (7...35).map { "second:\($0)" }
        #expect(delivered.withLock { $0 } == startsAndFinal + newest)
    }

}
