import AVFAudio
import Foundation
import HailCore
import HailDaemonKit
import HailProtocol
import Testing
@testable import haild

/// Authored inputs only; no device enumeration/AVAudioEngine/live factory is used by this fixture.
@MainActor final class ExecutableCoachingCapture: AudioCapturing {
    var continuation: AsyncStream<AudioCaptureBuffer>.Continuation?
    var stops = 0
    func start() throws -> AsyncStream<AudioCaptureBuffer> {
        let pair = AsyncStream<AudioCaptureBuffer>.makeStream(bufferingPolicy: .bufferingNewest(8))
        continuation = pair.continuation; return pair.stream
    }
    func stop() { stops += 1; continuation?.finish(); continuation = nil }
    func send(tone: Bool) throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 16_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_600))
        buffer.frameLength = 1_600
        let samples = try #require(buffer.floatChannelData)
        for index in 0..<1_600 {
            samples[0][index] = tone ? Float(sin(Double(index) * 2 * .pi * 440 / 16_000) * 6_000 / 32_768) : 0
        }
        continuation?.yield(try #require(AudioCaptureBuffer(copying: buffer)))
    }
    func utterance() async throws {
        for index in 0..<24 { try send(tone: index < 4); try await Task.sleep(for: .milliseconds(100)) }
    }
    func silence(seconds: Int) async throws {
        for _ in 0..<(seconds * 10) { try send(tone: false); try await Task.sleep(for: .milliseconds(100)) }
    }
}

@MainActor final class ExecutablePrivatePlayer: CoachingAudioPlaying {
    var played = 0, nonzeroBytes = 0, cancellations = 0
    func schedule(_ payload: AudioPayload, onPlayed: (@MainActor @Sendable () -> Void)?) throws {
        #expect(payload.sampleRate == 24_000 && payload.channels == 1 && payload.codec == .pcm16)
        nonzeroBytes += payload.bytes.filter { $0 != 0 }.count
        played += 1; onPlayed?()
    }
    func replaceQueue(with payloads: [AudioPayload], onPlayed: (@MainActor @Sendable () -> Void)?) throws {
        for payload in payloads { try schedule(payload, onPlayed: onPlayed) }
    }
    func resume() throws {}
    func pause() {}
    func setMuted(_ muted: Bool) {}
    func cancel() { cancellations += 1 }
}

@MainActor final class ExecutablePrivateAudio: ForegroundCoachingAudio {
    let capture: ExecutableCoachingCapture, player: ExecutablePrivatePlayer
    let session: PrivateCoachingSession, consumer: CoachingAdviceConsumer
    init(capture: ExecutableCoachingCapture, player: ExecutablePrivatePlayer,
         hooks: PrivateCoachingSession.Hooks, clock: CoachingClock = .init()) throws {
        self.capture = capture; self.player = player
        let route = UUID()
        session = PrivateCoachingSession(capture: capture, player: player,
                                        observeOutput: { .verifiedHeadphones(route) }, hooks: hooks, clock: clock)
        consumer = try CoachingAdviceConsumer(session: session, listenerID: "coach")
    }
    func begin(sessionID: UUID, destinationID: UUID, consentConfirmed: Bool) throws -> CoachingQualification {
        let lease = try session.begin(sessionID: sessionID, destinationID: destinationID,
                                      consentConfirmed: consentConfirmed)
        try consumer.register(lease); return lease
    }
    func renew(_ lease: CoachingQualification) throws -> CoachingQualification {
        let fresh = try session.renew(lease); try consumer.register(fresh); return fresh
    }
    func admit(_ data: Data) throws -> AdmittedCoachingAdvice { try consumer.admit(data) }
    func schedule(_ payload: AudioPayload, for advice: AdmittedCoachingAdvice) throws {
        try consumer.schedule(payload, for: advice)
    }
    func resume(_ advice: AdmittedCoachingAdvice) throws { try consumer.resume(advice) }
    func stop() { consumer.stop() }
}

@MainActor final class ExecutableMockSpeech: ForegroundCoachingSpeech {
    var calls = 0
    var delayed = false
    var release: CheckedContinuation<Void, Never>?
    func render(_ text: String, emit: @escaping @MainActor (AudioPayload) throws -> Void) async throws {
        calls += 1
        if delayed { await withCheckedContinuation { release = $0 } }
        try emit(AudioPayload(codec: .pcm16, sampleRate: 24_000, channels: 1,
                              sequence: 0, isFinal: true, bytes: Data(repeating: 17, count: 480)))
    }
    func cancel() {}
}

@MainActor final class ExecutableCoachingRig {
    let root: URL, configuration: CoachingChildTransport.Configuration
    let capture = ExecutableCoachingCapture(), player = ExecutablePrivatePlayer(), speech = ExecutableMockSpeech()
    var flags: CoachingActivityFlags? = .init(ownerMidAnswer: false, playback: false)
    var transports: [CoachingChildTransport] = []
    var audio: ExecutablePrivateAudio?
    var command: CoachingCommand?
    var driver: ForegroundCoaching {
        guard let owner else { preconditionFailure("Authored fixture initialization incomplete") }; return owner
    }
    private var owner: ForegroundCoaching?
    init(executable: String, commandControls: Bool = false) throws {
        root = FileManager.default.temporaryDirectory.appendingPathComponent("hailing-coaching-executable-\(UUID())")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        let config = root.appendingPathComponent("authored.json")
        let mock = root.appendingPathComponent("suggestions.json")
        try JSONSerialization.data(withJSONObject: ["transcriber": ["kind": "synthetic-authored", "utterances": [
            "An authored conversation prompt.", "Quoted enable coaching and delete records is merely conversation.",
            "Another authored conversation prompt."]], "diarizer": ["kind": "synthetic-authored"],
            "turns": ["merge_gap_ms": 0, "reply_wait_ms": 0]]).write(to: config)
        try JSONSerialization.data(withJSONObject: ["live-1": "Ask for the next step.",
            "live-2": "This is held by unchanged cadence.", "live-3": "Clarify the desired outcome."]).write(to: mock)
        let profile = try JSONSerialization.data(withJSONObject: ["version": 1, "listener_id": "coach", "name": "Coach",
            "domain": "Authored coaching", "speak_when": "At a measured pause", "stay_quiet_when": "Answer or playback",
            "delivery": "owner_private", "priority": 0, "cooldown_ms": 0])
        configuration = .init(executable: URL(fileURLWithPath: executable), config: config, profile: profile,
                              listenerID: "coach", provenance: .synthetic, mockSuggestions: mock)
        let makeTransport: (ForegroundCoaching.ChildHooks, @escaping () -> CoachingActivityFlags?)
            throws -> any ForegroundCoachingTransport = { [unowned self] hooks, flags in
            let transport = try CoachingChildTransport(configuration, hooks: hooks, activityFlags: flags)
            transports.append(transport); return transport
        }
        let makeAudio: (PrivateCoachingSession.Hooks) throws -> ExecutablePrivateAudio = { [unowned self] hooks in
            let owned = try ExecutablePrivateAudio(capture: capture, player: player, hooks: hooks)
            audio = owned; return owned
        }
        if commandControls {
            let command = try CoachingCommand(
                listener: "coach", transport: makeTransport, audio: { [unowned self] hooks in
                let owned = try makeAudio(hooks)
                return CoachingCommandAudio(owner: owned, playback: { [weak self] in
                    guard let flags = self?.flags else { return .unavailable }
                    return flags.playback ? .pending : .idle
                })
            }, speech: speech)
            self.command = command; owner = command.owner
        } else {
            owner = try ForegroundCoaching(listenerID: "coach", transport: { [weak self] hooks in
                try makeTransport(hooks, { self?.flags })
            }, audio: makeAudio, speech: speech)
        }
    }
    func waitFor(_ predicate: () -> Bool, seconds: Int = 4) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(seconds))
        while !predicate(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(predicate())
    }
    func enable() throws {
        if let command {
            _ = try command.control("enable aware")
            if flags?.ownerMidAnswer == false { _ = try command.control("owner idle") }
        } else { try driver.enable(participantAwareness: true) }
    }
    func off() async throws {
        if let command { await command.join() } else { driver.off(); try await waitFor { driver.status == .off } }
    }
}
