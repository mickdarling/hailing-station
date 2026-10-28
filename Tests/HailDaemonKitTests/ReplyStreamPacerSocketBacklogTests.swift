import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

/// #904: loopback LocalReplyEndpoint -> WebSocketListener -> paced synthetic reader, no device/provider/speech.
@Suite(.serialized) struct ReplyStreamPacerSocketBacklogTests {
    @Test(.timeLimit(.minutes(2))) func fortyFiveSecondReplyHasASmallUnreadSocketBacklog() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("hp-\(UUID().uuidString.prefix(8))")
        defer { try? FileManager.default.removeItem(at: scratch) }
        let rig = try await RecipientTestRig.make()
        let listener = try fallbackListener(rig: rig, enabled: false)
        let port = try await listener.start()
        let endpoint = try LocalReplyEndpoint(socketURL: scratch.appendingPathComponent("config/reply.sock"),
            destination: listener, audit: AuditLog(directory: scratch.appendingPathComponent("audit")))
        do {
            try await endpoint.start()
            let clients = try await FallbackSocketPair.connect(port: port, selecting: [RecipientTestRig.target])
            defer { clients.close() }
            let context = try await clients.submitInput(on: 0, rig: rig)
            let descriptor = recipientDescriptor(context, audio: true)
            let response = try await submit(
                FrameCoding.encode(recipientText(descriptor)), socket: endpoint.socketURL.path
            )
            try #require(response.delivered == 1)
            _ = try await recipientSocketReceive(on: clients.sockets[0])
            try await measure(descriptor, socket: endpoint.socketURL.path, terminal: clients.sockets[0])
            await endpoint.stop()
            await listener.stop()
        } catch {
            await endpoint.stop()
            await listener.stop()
            throw error
        }
    }

    private func measure(
        _ descriptor: ReplyDescriptor, socket: String, terminal: URLSessionWebSocketTask
    ) async throws {
        let backlog = SocketReplyBacklog()
        let reader = Task { try await readReply(on: terminal, backlog: backlog) }
        defer { reader.cancel(); terminal.cancel(with: .normalClosure, reason: nil) }
        var pacer = ReplyStreamPacer()
        let start = ContinuousClock.now
        var rendered = 0.0
        for sequence in 0..<37 {
            let frame = socketBacklogFrame(descriptor, sequence: sequence)
            guard case .audio(let audio) = frame.payload else { throw TestSupportError.expectedOneControl }
            let seconds = ReplyStreamPacer.seconds(pcm16Bytes: audio.bytes.count, sampleRate: 24_000)
            rendered += seconds
            try await Task.sleep(until: start.advanced(by: .seconds(rendered / 2.5)), clock: .continuous)
            let sendAt = try pacer.admit(audio: seconds, at: .now)
            try await Task.sleep(until: sendAt, clock: .continuous)
            let encoded = try FrameCoding.encode(frame)
            let response = try await submit(encoded, socket: socket)
            try #require(response.delivered == 1)
            backlog.sent(sequence, pcm: audio.bytes.count, json: encoded.count, seconds: seconds)
        }
        try await reader.value
        let result = backlog.result
        print("#904 socket: frames=\(result.frames) pcmBytes=\(result.pcm) jsonBytes=\(result.json) "
              + "leadSeconds=\(result.lead)")
        #expect(result.frames <= 5) // Includes a frame crossing the submit/read observation boundary.
        #expect(result.pcm <= 300_000)
        // One full frame plus 1 s for loopback observation scheduling under CI load.
        #expect(result.lead <= ReplyStreamPacer.leadSeconds + 1.25 + TestTiming.bound(1))
        #expect(result.read == 37)
    }

    private func readReply(on terminal: URLSessionWebSocketTask, backlog: SocketReplyBacklog) async throws {
        var first: ContinuousClock.Instant?
        var consumed = 0.0
        for sequence in 0..<37 {
            if let first { try await Task.sleep(until: first.advanced(by: .seconds(consumed)), clock: .continuous) }
            let frame = try await recipientSocketReceive(on: terminal, step: "synthetic paced reader")
            guard case .audio(let audio) = frame.payload else { throw TestSupportError.expectedOneControl }
            try #require(audio.sequence == sequence)
            first = first ?? .now
            backlog.read(sequence)
            consumed += ReplyStreamPacer.seconds(pcm16Bytes: audio.bytes.count, sampleRate: 24_000)
        }
    }
}

/// Same 24 kHz mono PCM ramp as StreamedReplyFrames; the deterministic CLI-target test uses that actual helper.
private func socketBacklogFrame(_ descriptor: ReplyDescriptor, sequence: Int) -> Frame {
    let size = sequence == 0 ? 24_000 : (sequence == 1 ? 36_000 : 60_000)
    return Frame(timestamp: 1, target: descriptor.targetID, source: descriptor.hostID,
        payload: .audio(AudioPayload(codec: .pcm16, sampleRate: 24_000, channels: 1, sequence: sequence,
            streamID: descriptor.audioStreamID, isFinal: false, bytes: Data(count: size), reply: descriptor)))
}

/// Counts acknowledged host sends not yet read by the application. URLSession/kernel prefetch is not observable.
private final class SocketReplyBacklog: Sendable {
    struct Result {
        var frames = 0, pcm = 0, json = 0, read = 0
        var lead = 0.0
    }
    private struct State {
        var unread: [Int: (pcm: Int, json: Int)] = [:]
        var read: Set<Int> = []
        var first: ContinuousClock.Instant?
        var audio = 0.0
        var result = Result()
    }
    private let state = Mutex(State())
    var result: Result { state.withLock { $0.result } }

    func sent(_ sequence: Int, pcm: Int, json: Int, seconds: Double) {
        state.withLock { value in
            let now = ContinuousClock.now
            let first = value.first ?? now
            value.first = first
            value.audio += seconds
            if !value.read.contains(sequence) { value.unread[sequence] = (pcm, json) }
            value.result.frames = max(value.result.frames, value.unread.count)
            value.result.pcm = max(value.result.pcm, value.unread.values.reduce(0) { $0 + $1.pcm })
            value.result.json = max(value.result.json, value.unread.values.reduce(0) { $0 + $1.json })
            let elapsed = first.duration(to: now).components
            value.result.lead = max(value.result.lead,
                value.audio - Double(elapsed.seconds) - Double(elapsed.attoseconds) / 1e18)
        }
    }

    func read(_ sequence: Int) {
        state.withLock {
            $0.read.insert(sequence)
            $0.unread[sequence] = nil
            $0.result.read = $0.read.count
        }
    }
}
