import Foundation
import HailProtocol
@testable import HailCore

@MainActor final class ForegroundTestClock {
    struct Alarm {
        let at: ContinuousClock.Instant
        let fire: () -> Void
        var cancelled = false
    }
    var now = ContinuousClock.now
    var alarms: [UUID: Alarm] = [:]
    var onSchedule: (() -> Void)?
    var clock: CoachingClock {
        CoachingClock(now: { self.now }, schedule: { delay, fire in
            let id = UUID()
            self.alarms[id] = Alarm(at: self.now.advanced(by: delay), fire: fire)
            self.onSchedule?()
            return { self.alarms[id]?.cancelled = true }
        })
    }
    func advance(_ by: Duration) {
        now = now.advanced(by: by)
        let due = alarms.filter { $0.value.at <= now && !$0.value.cancelled }
        for (id, alarm) in due { alarms[id] = nil; alarm.fire() }
    }
}

@MainActor final class ForegroundTestAudio: ForegroundCoachingAudio {
    let capture = FakeAudioCapture()
    let player = CoachingTestPlayer()
    let session: PrivateCoachingSession
    let consumer: CoachingAdviceConsumer
    init(hooks: PrivateCoachingSession.Hooks, clock: CoachingClock) throws {
        session = PrivateCoachingSession(capture: capture, player: player,
            observeOutput: { .verifiedHeadphones(Self.outputID) }, hooks: hooks, clock: clock)
        consumer = try CoachingAdviceConsumer(session: session, listenerID: "private-coach")
    }
    static let outputID = UUID()
    func begin(sessionID: UUID, destinationID: UUID, consentConfirmed: Bool) throws -> CoachingQualification {
        let lease = try session.begin(sessionID: sessionID, destinationID: destinationID,
                                      consentConfirmed: consentConfirmed)
        try consumer.register(lease)
        return lease
    }
    func renew(_ lease: CoachingQualification) throws -> CoachingQualification {
        let fresh = try session.renew(lease)
        try consumer.register(fresh)
        return fresh
    }
    func admit(_ data: Data) throws -> AdmittedCoachingAdvice { try consumer.admit(data) }
    func schedule(_ payload: AudioPayload, for advice: AdmittedCoachingAdvice) throws {
        try consumer.schedule(payload, for: advice)
    }
    func resume(_ advice: AdmittedCoachingAdvice) throws { try consumer.resume(advice) }
    func stop() { consumer.stop() }
}

@MainActor final class ForegroundTestChild: ForegroundCoachingTransport {
    let hooks: ForegroundCoaching.ChildHooks
    var leases: [CoachingQualification] = []
    var enableCount = 0, buffers = 0, closes = 0, stops = 0
    var onSend: (() -> Void)?
    var blockedStop: CheckedContinuation<Void, Never>?
    var holdStop = false
    init(_ hooks: ForegroundCoaching.ChildHooks) { self.hooks = hooks }
    func send(_ control: ForegroundCoachingControl) -> Bool {
        if case .qualify(let lease) = control { leases.append(lease) }
        if case .enable = control { enableCount += 1 }
        onSend?()
        return true
    }
    func write(_ buffer: AudioCaptureBuffer) -> Bool { buffers += 1; return closes == 0 }
    func close() { closes += 1 }
    func stop() async {
        stops += 1
        if holdStop { await withCheckedContinuation { blockedStop = $0 } }
    }
}

@MainActor final class ForegroundTestSpeech: ForegroundCoachingSpeech {
    var texts: [String] = []
    var cancellations = 0
    var handler: ((@escaping @MainActor (AudioPayload) throws -> Void) async throws -> Void)?
    func render(_ text: String, emit: @escaping @MainActor (AudioPayload) throws -> Void) async throws {
        texts.append(text)
        if let handler { try await handler(emit) } else { try emit(coachingPCM) }
    }
    func cancel() { cancellations += 1 }
}

@MainActor final class ForegroundRig {
    let time = ForegroundTestClock()
    let speech = ForegroundTestSpeech()
    var children: [ForegroundTestChild] = []
    var owners: [ForegroundTestAudio] = []
    var onChild: ((ForegroundTestChild) -> Void)?
    var driver: ForegroundCoaching {
        guard let owner else { preconditionFailure("Synthetic rig not initialized") }
        return owner
    }
    private var owner: ForegroundCoaching?
    init() throws {
        owner = try ForegroundCoaching(listenerID: "private-coach", transport: { [unowned self] hooks in
            let child = ForegroundTestChild(hooks)
            children.append(child); onChild?(child)
            return child
        }, audio: { [unowned self] hooks in
            let owner = try ForegroundTestAudio(hooks: hooks, clock: time.clock)
            owners.append(owner)
            return owner
        }, speech: speech, clock: time.clock)
    }
}
