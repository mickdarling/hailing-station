import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

extension WebSocketReceivePumpTests {
    // Virtual 100 ms sender ticks and acknowledged receives model a >3 s dispatch stall without sleeping.
    @Test(arguments: [false, true])
    func audioWindowSurvivesParkedDispatchAndObservesClose(closeDuringStall: Bool) async throws {
        let rig = PumpRig()
        let park = PumpAudioPark()
        let stream = UUID()
        let delivered = Mutex<[Int]>([])
        let clock = AmbientTestClock()
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
        for sequence in 0...35 {
            clock.advance(.milliseconds(100))
            rig.transport.deliver(.application(try pumpAudio(stream, sequence)))
            #expect(rig.transport.outstanding == 1)
            #expect(!rig.lifecycle.isRetired)
        }
        // A full window makes room for the final by evicting its oldest eligible segment.
        rig.transport.deliver(.application(try pumpAudio(stream, 36, final: true)))
        #expect(rig.pump.droppedAudioCount == 6)
        #expect(delivered.withLock { $0.isEmpty })
        if closeDuringStall {
            rig.transport.deliver(.terminal("peer closed"))
            #expect(try await rig.ended.wait("close before release") == "peer closed")
            #expect(rig.lifecycle.isRetired)
        }
        park.release.finish(.success(()))
        await worker.value
        let expected = closeDuringStall ? [] : [0] + Array(7...36)
        #expect(delivered.withLock { $0 } == expected)
        #expect(rig.pump.droppedAudioCount == 6)
        #expect(rig.transport.maximumOutstanding == 1)
    }

    @Test func privacyControlRemainsAheadOfLaterAudio() async throws {
        let rig = PumpRig()
        let park = PumpAudioPark()
        let sink = RecordingAmbientSink()
        let clock = AmbientTestClock()
        let gate = ambientGate(sink: sink, clock: clock)
        let connection = UUID()
        let stream = UUID()
        let applied = Mutex(false)
        let admitted = Mutex<[Int]>([])
        defer { park.release.finish(.success(())); rig.pump.stop() }
        rig.start { frame in
            guard let frame else { Issue.record("expected frame"); return }
            switch frame.payload {
            case .control(.setPrivacy(let on)):
                await gate.setPrivacy(on, connection: connection)
                applied.withLock { $0 = true }
            case .audio(let audio):
                #expect(applied.withLock { $0 })
                clock.advance(.milliseconds(100))
                let error = await gate.admit(audio, connection: connection)
                #expect(error == nil)
                admitted.withLock { $0.append(audio.sequence) }
            default: await park.wait()
            }
        }
        // Open the gate first, as privacy belongs to the active owner.
        #expect(await gate.admit(ambientSegment(stream: stream, sequence: 0), connection: connection) == nil)
        rig.transport.deliver(.application(try pumpMarker(1)))
        try await park.entered.wait("privacy dispatch parked")
        let worker = try #require(rig.pump.worker)
        let privacy = sessionFrame(payload: .control(.setPrivacy(on: true)))
        rig.transport.deliver(.application(try FrameCoding.encode(privacy)))
        for sequence in 1...35 { rig.transport.deliver(.application(try pumpAudio(stream, sequence))) }
        #expect(!applied.withLock { $0 })
        #expect(sink.segments == [0])
        park.release.finish(.success(()))
        await worker.value
        #expect(applied.withLock { $0 })
        #expect(admitted.withLock { $0 } == Array(6...35))
        #expect(sink.segments == [0] + Array(6...35))
        #expect(!rig.lifecycle.isRetired)
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
        #expect(rig.pump.droppedAudioCount == 6)
        park.release.finish(.success(()))
        await worker.value
        // Same wire stream with the same holes already present on arrival from the phone.
        for sequence in [0] + Array(7...36) {
            let frame = try FrameCoding.decode(pumpAudio(stream, sequence, final: sequence == 36))
            guard case .audio(let audio) = frame.payload else { Issue.record("expected audio"); return }
            phoneClock.advance(.milliseconds(100))
            #expect(await phoneGate.admit(audio, connection: connection) == nil)
        }
        #expect(hostSink.segments == [0] + Array(7...36))
        #expect(hostSink.events == phoneSink.events)
        let hostBytes = pumpSinkBytes(hostSink)
        let phoneBytes = pumpSinkBytes(phoneSink)
        #expect(hostBytes == phoneBytes)
        #expect(hostBytes.count == 31 * 3_200)
        #expect(hostSink.endings == [.final])
    }

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
}

private struct PumpAudioPark: Sendable {
    let entered = SelectionPreflightSignal<Void>()
    let release = SelectionPreflightSignal<Void>()
    func wait() async {
        entered.finish(.success(()))
        _ = try? await release.wait("audio dispatch release")
    }
}

private func pumpAudio(_ stream: UUID, _ sequence: Int, final: Bool = false) throws -> Data {
    var audio = ambientSegment(stream: stream, sequence: sequence, isFinal: final)
    audio.bytes = Data(repeating: UInt8(sequence % 256), count: 3_200)
    return try FrameCoding.encode(sessionFrame(payload: .audio(audio)))
}

private func pumpSinkBytes(_ sink: RecordingAmbientSink) -> Data {
    var bytes = Data()
    for event in sink.events {
        if case .segment(_, _, let chunk) = event { bytes.append(chunk) }
    }
    return bytes
}
