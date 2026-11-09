import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

extension WebSocketReceivePumpTests {
    @Test func audioBoundsUseAmbientSegmentSize() {
        #expect(AmbientAudioGate.maxSegmentBytes == 8_192)
        #expect(WebSocketIngressPump.ambientSegmentWireBytes == 15_020)
        #expect(WebSocketIngressPump.maxAudioBytes == 450_600)
        #expect(WebSocketIngressPump.maxNonAudioBytes == 182_954)
        #expect(WebSocketIngressPump.maxQueuedBytes == 648_574)
    }

    @Test(arguments: [2, AmbientAudioGate.maxSegmentBytes])
    func wholeSampleBoundariesRemainEligible(byteCount: Int) async throws {
        let stream = UUID()
        let connection = UUID()
        let gate = ambientGate(sink: RecordingAmbientSink(), clock: AmbientTestClock())
        #expect(await gate.admit(ambientSegment(stream: stream, sequence: 0), connection: connection) == nil)
        let audio = ambientSegment(stream: stream, sequence: 1, bytes: byteCount)
        let frame = sessionFrame(target: "tmux:a", payload: .audio(audio))
        var data = try FrameCoding.encode(frame)
        data.append(Data(repeating: 32, count: WebSocketIngressPump.ambientSegmentWireBytes - data.count))
        #expect(AmbientAudioGate.isWindowEligible(frame, wireBytes: data.count))
        #expect(await gate.admit(audio, connection: connection) == nil)
        guard case .audio = WebSocketIngressPump.Message(data).retained else {
            Issue.record("sample boundary should retain decoded audio")
            return
        }
    }

    @Test(arguments: pumpIneligibleFields, [false, true])
    func ineligibleAudioUsesProtectedCapacity(field: String, overflow: Bool) async throws {
        let rig = PumpRig()
        let park = PumpAudioPark()
        let stream = UUID()
        let delivered = Mutex<[Frame]>([])
        defer { park.release.finish(.success(())); rig.pump.stop() }
        rig.start { frame in
            if frame?.timestamp == 1 { await park.wait() } else if let frame { delivered.withLock { $0.append(frame) } }
        }
        rig.transport.deliver(.application(try pumpMarker(1)))
        try await park.entered.wait("eligibility dispatch parked")
        let worker = try #require(rig.pump.worker)
        var expected: [Frame] = []
        for sequence in 1...30 {
            let data = try pumpAudio(stream, sequence)
            expected.append(try FrameCoding.decode(data))
            rig.transport.deliver(.application(data))
        }
        let data = try pumpIneligibleData(field, stream: stream)
        let decoded = try FrameCoding.decode(data)
        #expect(!AmbientAudioGate.isWindowEligible(decoded, wireBytes: data.count))
        for _ in 0..<8 { rig.transport.deliver(.application(data)) }
        #expect(!rig.lifecycle.isRetired)
        #expect(rig.pump.droppedAudioCount == 0)
        #expect(rig.transport.outstanding == 1)
        if overflow {
            rig.transport.deliver(.application(data))
            #expect(rig.lifecycle.isRetired)
            #expect(try await rig.ended.wait("ineligible audio count overflow") == "receive queue limit")
        }
        park.release.finish(.success(()))
        await worker.value
        let protectedFrames = Array(repeating: decoded, count: 8)
        #expect(delivered.withLock { $0 } == (overflow ? [] : expected + protectedFrames))
        #expect(rig.pump.droppedAudioCount == 0)
    }

    @Test func retainedRepresentationMatchesEligibilityAndWorkerDecode() throws {
        let payload = JSONValue.array(Array(repeating: .null, count: 500))
        let unknown = sessionFrame(payload: .unknown(type: "future", payload: payload))
        let typed = sessionFrame(payload: .text(TextPayload(text: String(repeating: "x", count: 8_000))))
        for frame in [unknown, typed] {
            let data = try FrameCoding.encode(frame)
            let message = WebSocketIngressPump.Message(data)
            guard case .raw(let retained) = message.retained else { Issue.record("expected raw data"); continue }
            #expect(retained == data)
            #expect(message.frame == frame)
            #expect(message.droppableSequence == nil)
        }
        let data = try pumpAudio(UUID(), 1)
        let message = WebSocketIngressPump.Message(data)
        guard case .audio(let retained) = message.retained else { Issue.record("expected decoded audio"); return }
        #expect(retained == (try FrameCoding.decode(data)))
        #expect(message.frame == retained)
        #expect(message.droppableSequence == 1)
    }

    @Test func overBoundFrameRetainsRawBytesForWorkerDecode() throws {
        let data = try pumpIneligibleData("wire", stream: UUID())
        #expect(data.count == WebSocketIngressPump.ambientSegmentWireBytes + 1)
        let frame = try FrameCoding.decode(data)
        #expect(!AmbientAudioGate.isWindowEligible(frame, wireBytes: data.count))
        let message = try #require(WebSocketIngressPump.Message.classify(.application(data)))
        guard case .raw(let retained) = message.retained else { Issue.record("expected raw data"); return }
        #expect(retained == data)
        #expect(!message.audioWindow)
        #expect(message.droppableSequence == nil)
        #expect(message.frame == frame)
    }

    @Test(arguments: pumpIneligibleFields + ["eligible"])
    func eligibilityMirrorsGateShapeWithoutChangingAdmission(field: String) async throws {
        let stream = UUID()
        let connection = UUID()
        let sink = RecordingAmbientSink()
        let gate = ambientGate(sink: sink, clock: AmbientTestClock())
        #expect(await gate.admit(ambientSegment(stream: stream, sequence: 0), connection: connection) == nil)
        let data = try pumpIneligibleData(field, stream: field == "zeroSequence" ? UUID() : stream)
        let frame = try FrameCoding.decode(data)
        guard case .audio(let audio) = frame.payload else { Issue.record("expected audio"); return }
        let eligible = AmbientAudioGate.isWindowEligible(frame, wireBytes: data.count)
        let result = await gate.admit(audio, connection: connection)
        // Envelope/wire limits belong to ingress; starts and finals remain gate-admissible.
        let gateOnlyAccepted = ["version", "wire", "zeroSequence", "final"].contains(field)
        #expect(eligible == (field == "eligible"))
        #expect((result == nil) == (eligible || gateOnlyAccepted))
        #expect(sink.segments == ((eligible || gateOnlyAccepted) ? [0, audio.sequence] : [0]))
    }
}

let pumpIneligibleFields = [
    "reply", "stream", "codec", "rate", "channels", "segmentEnd", "odd", "empty", "large", "version", "wire",
    "zeroSequence", "final"
]

func pumpIneligibleData(_ field: String, stream: UUID) throws -> Data {
    var audio = ambientSegment(stream: stream, sequence: 1)
    let version = ProtocolVersion.current + (field == "version" ? 1 : 0)
    let byteCounts = ["odd": 3, "empty": 0, "large": AmbientAudioGate.maxSegmentBytes + 2]
    if let count = byteCounts[field] { audio.bytes = Data(count: count) }
    switch field {
    case "reply", "segmentEnd":
        audio.reply = ReplyDescriptor(id: UUID(), hostID: "h", targetID: "tmux:a", audioStreamID: stream)
        audio.isSegmentEnd = field == "segmentEnd"
    case "stream": audio.streamID = nil
    case "codec": audio.codec = .opus
    case "rate": audio.sampleRate = 48_000
    case "channels": audio.channels = 2
    case "zeroSequence": audio.sequence = 0
    case "final": audio.isFinal = true
    default: break
    }
    let frame = Frame(version: version, timestamp: 2, target: "tmux:a", source: "h", payload: .audio(audio))
    var data = try FrameCoding.encode(frame)
    if field == "wire" {
        data.append(Data(repeating: 32, count: WebSocketIngressPump.ambientSegmentWireBytes + 1 - data.count))
    }
    return data
}
