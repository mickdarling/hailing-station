import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

extension WebSocketReceivePumpTests {
    // Burst pressure equivalent to more than 3 s at 10 Hz; barriers establish ordering.
    @Test(arguments: [false, true], [false, true])
    func audioWindowSurvivesParkedDispatchAndObservesClose(
        closeDuringStall: Bool, paced: Bool
    ) async throws {
        let rig = PumpRig()
        let park = PumpAudioPark()
        let stream = UUID()
        let delivered = Mutex<[Int]>([])
        defer { park.release.finish(.success(())); rig.pump.stop() }
        rig.start { frame in
            guard let frame else { Issue.record("expected decoded frame"); return }
            if case .audio(let audio) = frame.payload {
                delivered.withLock { $0.append(audio.sequence) }
            } else { await park.wait() }
        }
        rig.transport.deliver(.application(try pumpMarker(1)))
        try await park.entered.wait("dispatch parked")
        let worker = try #require(rig.pump.worker)
        let senderClock = ContinuousClock()
        let senderStart = senderClock.now
        for sequence in 0...35 {
            // Wall-clock pacing shapes arrival only; the acknowledged park owns the ordering proof.
            if paced { try await senderClock.sleep(until: senderStart + .milliseconds(sequence * 100)) }
            rig.transport.deliver(.application(try pumpAudio(stream, sequence)))
            #expect(rig.transport.outstanding == 1)
            #expect(!rig.lifecycle.isRetired)
        }
        // A final uses protected capacity without evicting any eligible segment.
        rig.transport.deliver(.application(try pumpAudio(stream, 36, final: true)))
        #expect(rig.pump.droppedAudioCount == 5)
        await rig.pump.waitForDropLogging()
        #expect(rig.drops.count == 5)
        #expect(rig.drops.ranges.flatMap { Array($0) } == Array(1...5))
        #expect(delivered.withLock { $0.isEmpty })
        if closeDuringStall {
            rig.transport.deliver(.terminal("peer closed"))
            #expect(try await rig.ended.wait("close before release") == "peer closed")
            #expect(rig.lifecycle.isRetired)
        }
        park.release.finish(.success(()))
        await worker.value
        let expected = closeDuringStall ? [] : [0] + Array(6...36)
        #expect(delivered.withLock { $0 } == expected)
        #expect(rig.pump.droppedAudioCount == 5)
        #expect(rig.transport.maximumOutstanding == 1)
    }

    @Test func hostDropsMatchPhoneDropsAtGateAndAmbientSink() async throws {
        let rig = PumpRig()
        let park = PumpAudioPark()
        let stream = UUID()
        let connection = UUID()
        let hostSink = RecordingAmbientSink()
        let phoneSink = RecordingAmbientSink()
        let hostClock = AmbientTestClock()
        let phoneClock = AmbientTestClock()
        let hostGate = ambientGate(sink: hostSink, clock: hostClock)
        let phoneGate = ambientGate(sink: phoneSink, clock: phoneClock)
        defer { park.release.finish(.success(())); rig.pump.stop() }
        rig.start { frame in
            guard let frame else { Issue.record("expected frame"); return }
            guard case .audio(let audio) = frame.payload else { await park.wait(); return }
            hostClock.advance(.milliseconds(100))
            #expect(await hostGate.admit(audio, connection: connection) == nil)
        }
        rig.transport.deliver(.application(try pumpMarker(1)))
        try await park.entered.wait("parity dispatch parked")
        let worker = try #require(rig.pump.worker)
        for sequence in 0...36 {
            rig.transport.deliver(.application(try pumpAudio(stream, sequence, final: sequence == 36)))
        }
        #expect(rig.pump.droppedAudioCount == 5)
        park.release.finish(.success(()))
        await worker.value
        // Same wire stream with the same holes already present on arrival from the phone.
        for sequence in [0] + Array(6...36) {
            let frame = try FrameCoding.decode(pumpAudio(stream, sequence, final: sequence == 36))
            guard case .audio(let audio) = frame.payload else { Issue.record("expected audio"); return }
            phoneClock.advance(.milliseconds(100))
            #expect(await phoneGate.admit(audio, connection: connection) == nil)
        }
        #expect(hostSink.segments == [0] + Array(6...36))
        #expect(hostSink.events == phoneSink.events)
        let hostBytes = pumpSinkBytes(hostSink)
        let phoneBytes = pumpSinkBytes(phoneSink)
        #expect(hostBytes == phoneBytes)
        #expect(hostBytes.count == 32 * 3_200)
        #expect(hostSink.endings == [.final])
    }
}

struct PumpAudioPark: Sendable {
    let entered = SelectionPreflightSignal<Void>()
    let release = SelectionPreflightSignal<Void>()
    func wait() async {
        entered.finish(.success(()))
        _ = try? await release.wait("audio dispatch release", timeout: .seconds(15))
    }
}

func pumpAudio(_ stream: UUID, _ sequence: Int, final: Bool = false) throws -> Data {
    var audio = ambientSegment(stream: stream, sequence: sequence, isFinal: final)
    audio.bytes = Data(repeating: UInt8(sequence % 256), count: 3_200)
    return try FrameCoding.encode(sessionFrame(target: "tmux:a", payload: .audio(audio)))
}

private func pumpSinkBytes(_ sink: RecordingAmbientSink) -> Data {
    var bytes = Data()
    for event in sink.events {
        if case .segment(_, _, let chunk) = event { bytes.append(chunk) }
    }
    return bytes
}
