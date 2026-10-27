import AVFAudio
import Foundation
import HailProtocol
import Testing
@testable import HailCore

/// Synthetic constant-amplitude PCM has exactly the requested RMS dBFS; never uses a microphone.
func onsetPCM(_ dbfs: Double, seconds: Double = 0.1, rate: Double = 48_000) throws -> AVAudioPCMBuffer {
    let format = try #require(AVAudioFormat(standardFormatWithSampleRate: rate, channels: 1))
    let frames = AVAudioFrameCount((seconds * rate).rounded())
    let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames))
    buffer.frameLength = frames
    let samples = try #require(buffer.floatChannelData?[0])
    samples.initialize(repeating: Float(pow(10, dbfs / 20)), count: Int(frames))
    return buffer
}

final class OnsetFixture {
    let clock = EchoGuardClock()
    let guarder: AmbientReplyEchoGuard
    var window: Range<ContinuousClock.Instant>?
    var ambient = true
    var privacy = false
    var settings = ReplySegmentSettings()
    var gate: ReplySegmentOnsetGate { guarder.segmentOnsetGate }
    var input: ReplySegmentOnsetInput {
        .init(window: window, ambientListening: ambient, privacyOn: privacy, settings: settings)
    }

    init(tail: Duration = AmbientReplyEchoGuard.defaultTail, length: Double = 1.5) {
        let clock = clock
        guarder = AmbientReplyEchoGuard(tail: tail, now: { clock.now })
        open(length: length)
    }

    func open(length: Double = 1.5) {
        window = clock.now..<clock.now.advanced(by: .seconds(length))
    }

    @discardableResult
    func feed(_ dbfs: Double, seconds: Double = 0.1) throws -> Bool {
        let buffer = try onsetPCM(dbfs, seconds: seconds)
        clock.advance(by: .seconds(seconds))
        return gate.analyse(buffer, input: input)
    }

    func calibrate(floor: Double = -50) throws {
        #expect(try !feed(0, seconds: 0.4)) // Echo tail must never enter the floor.
        #expect(try !feed(floor, seconds: 0.2))
    }
}

/// Real store/connection dispatch and pre-mask tap, with synthetic PCM and a fake player only.
@MainActor
final class SegmentWireFixture {
    let store: HostConnectionStore
    let connector = ScriptedConnector()
    let clock = EchoGuardClock()
    let player = IdlePlayer()
    let controller: ReplyPlaybackController
    let guarder: AmbientReplyEchoGuard
    let reply = idleReply()
    var ambient = true
    var privacy = false
    private var timers: [(ContinuousClock.Instant, @MainActor () -> Void)] = []

    init() {
        let clock = clock
        store = HostConnectionStore(connector: connector)
        controller = ReplyPlaybackController(player: player)
        controller.idleNow = { clock.now }
        guarder = AmbientReplyEchoGuard(now: { clock.now })
        controller.idleScheduler = { [weak self] delay, fire in
            self?.timers.append((clock.now.advanced(by: delay), fire))
            return {}
        }
        store.wireReplySegments(playback: controller, echoGuard: guarder) { [weak self] _ in
            (self?.ambient == true, self?.privacy ?? true)
        }
    }

    func connect(_ id: String, ready: Bool = true, capable: Bool = true) async throws -> ScriptedSocket {
        let endpoint = try endpoint(id, "ws://127.0.0.1:" + (id == "main" ? "8765" : "8766"))
        let socket = ScriptedSocket()
        await connector.enqueue(.socket(socket), for: endpoint.url)
        await store.upsert(endpoint)
        await store.connect(id)
        try await waitUntil { @MainActor in self.store.snapshots[id]?.state == .negotiating }
        if ready {
            try await socket.push(.hello(HelloInfo(
                versions: [ProtocolVersion.current],
                capabilities: capable ? [ReplySegments.capability] : [], deviceName: "Synthetic host"
            )))
            try await waitUntil { @MainActor in self.store.snapshots[id]?.state == .ready }
        }
        return socket
    }

    func open(played: Int = 1) async throws {
        for sequence in 0..<played {
            if sequence > 0 {
                clock.advance(by: .seconds(1.5))
                let due = timers.filter { $0.0 <= clock.now }
                timers.removeAll { $0.0 <= clock.now }
                for timer in due { timer.1() }
            }
            controller.ingest(segmentAudio(reply, sequence: sequence))
            player.completeReply()
        }
        try await waitUntil { @MainActor in self.store.segmentWiring?.captureInput().window != nil }
    }

    func feed(_ dbfs: Double, seconds: Double, afterAuthorization: @escaping @Sendable () -> Void = {}) async throws {
        let buffer = try #require(AudioCaptureBuffer(copying: onsetPCM(dbfs, seconds: seconds)))
        clock.advance(by: .seconds(seconds))
        let guarder = guarder
        await Task.detached {
            guarder.observeSegmentOnset(buffer.pcmBuffer, afterAuthorization: afterAuthorization)
        }.value
    }

    func calibrate() async throws {
        try await feed(-50, seconds: 0.4)
        try await feed(-50, seconds: 0.2)
    }

    func detect() async throws {
        try await calibrate()
        try await feed(-20, seconds: 0.3)
    }

    func cleanup() async {
        for id in store.order { await store.disconnect(id) }
    }
}
