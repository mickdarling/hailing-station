import AVFAudio
import Foundation
import HailProtocol
import Testing
@testable import HailCore

private func int16Samples(_ payloads: [AudioPayload]) -> [Int16] {
    payloads.flatMap { payload in
        payload.bytes.withUnsafeBytes { Array($0.bindMemory(to: Int16.self)) }
    }
}

@Suite struct AmbientAudioEncoderTests {
    @Test func convertsA48kHzSineTo16kHzMonoPCM16() throws {
        let streamID = UUID()
        var encoder = try AmbientAudioEncoder(streamID: streamID)
        var payloads: [AudioPayload] = []
        for block in 0..<10 {
            payloads += try encoder.encode(sineBuffer(offset: block * 4_800))
        }
        payloads += try encoder.finish()

        let samples = int16Samples(payloads)
        // One second at 16 kHz, give or take converter edge latency.
        #expect((15_900...16_100).contains(samples.count))
        let peak = samples.map { abs(Int($0)) }.max() ?? 0
        #expect((14_000...18_000).contains(peak))
        let settled = samples.dropFirst(200).dropLast(200)
        let crossings = zip(settled, settled.dropFirst()).count { $0 < 0 && $1 >= 0 }
        // A 1 kHz tone keeps about 1,000 upward crossings per second after resampling.
        #expect((900...1_000).contains(crossings))

        for payload in payloads {
            #expect(payload.codec == .pcm16)
            #expect(payload.sampleRate == 16_000)
            #expect(payload.channels == 1)
            #expect(payload.streamID == streamID)
            #expect(payload.reply == nil)
        }
        #expect(payloads.dropLast().allSatisfy { $0.bytes.count == 3_200 && !$0.isFinal })
        #expect(payloads.last?.isFinal == true)
        #expect(payloads.map(\.sequence) == Array(0..<payloads.count))
    }

    @Test func rebuildsTheConverterWhenTheRouteFormatChanges() throws {
        var encoder = try AmbientAudioEncoder(streamID: UUID())
        var payloads = try encoder.encode(sineBuffer())
        payloads += try encoder.encode(sineBuffer(frames: 4_410, sampleRate: 44_100))
        payloads += try encoder.finish()
        let samples = int16Samples(payloads)
        #expect((3_100...3_300).contains(samples.count))
        #expect(payloads.map(\.sequence) == Array(0..<payloads.count))
    }
}

@MainActor
@Suite struct AmbientAudioStreamerTests {
    @Test func chunksSequencesAndEndsWithFinalOnStop() async throws {
        let capture = FakeAudioCapture()
        let sent = SentAudio()
        let identity = UUID()
        let streamer = AmbientAudioStreamer(
            capture: capture, makeStreamID: { identity }, send: { await sent.send($0) }
        )

        try streamer.start()
        #expect(streamer.isStreaming)
        #expect(throws: AudioCaptureError.alreadyRunning) { try streamer.start() }
        for block in 0..<5 { try capture.yield(sineBuffer(offset: block * 4_800)) }
        // One segment is held back so the final flag can ride on audio.
        try await waitUntil { await sent.payloads.count >= 3 }
        #expect(await sent.payloads.allSatisfy { !$0.isFinal })

        await streamer.stop()
        let payloads = await sent.payloads
        #expect(!streamer.isStreaming)
        #expect(capture.stopCount >= 1)
        #expect(streamer.streamID == identity)
        #expect(payloads.allSatisfy { $0.streamID == identity })
        #expect(payloads.map(\.sequence) == Array(0..<payloads.count))
        #expect(payloads.dropLast().allSatisfy { $0.bytes.count == AmbientAudioFormat.chunkBytes && !$0.isFinal })
        #expect(payloads.last?.isFinal == true)
        #expect(payloads.reduce(0) { $0 + $1.bytes.count } / 2 > 7_900)
        #expect(payloads.allSatisfy { !$0.bytes.isEmpty })
    }

    @Test func eachStartIsANewStreamFromSequenceZero() async throws {
        let capture = FakeAudioCapture()
        let sent = SentAudio()
        let streamer = AmbientAudioStreamer(capture: capture) { await sent.send($0) }

        try streamer.start()
        try capture.yield(sineBuffer())
        await streamer.stop()
        try streamer.start()
        try capture.yield(sineBuffer())
        await streamer.stop()

        let payloads = await sent.payloads
        let streams = Array(Set(payloads.compactMap(\.streamID)))
        #expect(streams.count == 2)
        for stream in streams {
            let segments = payloads.filter { $0.streamID == stream }
            #expect(segments.first?.sequence == 0)
            #expect(segments.last?.isFinal == true)
            #expect(segments.count { $0.isFinal } == 1)
        }
    }

    @Test func dropsTheOldestAudioOnceTheBacklogExceedsOneSecond() async throws {
        let capture = FakeAudioCapture()
        let sent = SentAudio(holding: true)
        let encoded = SentAudio()
        let streamer = AmbientAudioStreamer(
            capture: capture, maxBacklogChunks: AmbientAudioFormat.maxBacklogChunks, makeStreamID: { UUID() },
            beforeEncode: { await encoded.send(encodeMarker) }, send: { await sent.send($0) }
        )

        try streamer.start()
        // Hand over one buffer at a time so the capture bound (tested separately) never drops here.
        for block in 0..<25 {
            try capture.yield(sineBuffer(offset: block * 4_800))
            try await waitUntil { await encoded.payloads.count == block + 1 }
        }
        // About 24 segments: one in flight, ten pending, the rest dropped oldest-first.
        try await waitUntil { await streamer.droppedChunkCount >= 12 }
        await sent.release()
        await streamer.stop()
        #expect(await streamer.droppedCaptureBufferCount == 0)

        let payloads = await sent.payloads
        let sequences = payloads.map(\.sequence)
        #expect(sequences.first == 0)
        #expect(zip(sequences, sequences.dropFirst()).allSatisfy { $0 < $1 })
        // In flight + one second pending + the flushed tail (at most one full segment and the final one).
        #expect(sequences.count <= 1 + AmbientAudioFormat.maxBacklogChunks + 2)
        #expect(sequences[1] > 1)
        #expect(payloads.last?.isFinal == true)
        #expect(payloads.count { $0.isFinal } == 1)
    }

    @Test func aFailedSendStopsCaptureWithoutAFinalSegment() async throws {
        let capture = FakeAudioCapture()
        let attempts = SentAudio()
        let streamer = AmbientAudioStreamer(capture: capture) { payload in
            await attempts.send(payload)
            throw HostConnectionFailure.unsupportedCapability("stream_audio")
        }

        try streamer.start()
        for block in 0..<3 { try capture.yield(sineBuffer(offset: block * 4_800)) }
        try await waitUntil { await !streamer.isStreaming }

        #expect(capture.stopCount >= 1)
        let failure = await streamer.failure as? HostConnectionFailure
        #expect(failure == .unsupportedCapability("stream_audio"))
        #expect(await attempts.payloads.count == 1)
        #expect(await attempts.payloads.allSatisfy { !$0.isFinal })
        await streamer.stop()
    }

    @Test func aGateRefusalStopsTheStreamerAndReleasesTheMicrophone() async throws {
        let (connection, socket) = try await readyAudioConnection(capabilities: ["select_target", "stream_audio"])
        let capture = FakeAudioCapture()
        let streamer = AmbientAudioStreamer(capture: capture) { try await connection.sendAudio($0) }

        try streamer.start()
        for block in 0..<3 { try capture.yield(sineBuffer(offset: block * 4_800)) }
        try await waitUntil { try await !audioFrames(socket).isEmpty }
        try await socket.push(.error(code: .rateLimited, message: "ambient rate exceeded"))
        // Live capture keeps producing audio; the next segment of the refused stream ends it.
        for block in 3..<100 where streamer.isStreaming {
            try capture.yield(sineBuffer(offset: block * 4_800))
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(!streamer.isStreaming)
        #expect(capture.stopCount >= 1)
        let failure = await streamer.failure as? HostConnectionFailure
        #expect(failure == .remote("rate_limited: ambient rate exceeded"))
        #expect(await connection.currentSnapshot().state == .ready)
        #expect(try await audioFrames(socket).allSatisfy {
            if case .audio(let audio) = $0.payload { return !audio.isFinal }
            return false
        })
        await connection.disconnect()
    }

    @Test func droppingTheStreamerStopsCapture() async throws {
        let capture = FakeAudioCapture()
        let sent = SentAudio()
        var streamer: AmbientAudioStreamer? = AmbientAudioStreamer(capture: capture) { await sent.send($0) }
        try streamer?.start()
        try capture.yield(sineBuffer())
        streamer = nil
        #expect(streamer == nil)

        try await waitUntil { await MainActor.run { capture.stopCount >= 1 } }
        try await waitUntil { await sent.payloads.last?.isFinal == true }
    }
}
