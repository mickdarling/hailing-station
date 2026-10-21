public import Foundation
import HailProtocol

/// Foreground local opt-in coordinator (#269). Neither init nor linking this library starts audio.
/// HailCore owns no process, fd, provider, target, socket, daemon or action dispatcher. The executable
/// supplies trusted adapters and independently validated profiles; child output is advice data only.
@MainActor
public final class ForegroundCoaching {
    public struct ChildHooks {
        public let advice: (Data) -> Void
        public let ended: () -> Void
    }
    public typealias TransportFactory = (ChildHooks) throws -> any ForegroundCoachingTransport
    public typealias AudioFactory = (PrivateCoachingSession.Hooks) throws -> any ForegroundCoachingAudio

    public internal(set) var status = ForegroundCoachingStatus.off
    /// Why the latest run ended, recorded only when the private audio ended a starting or active run (#645).
    /// A local Off leaves it nil. Content-free; cleared by the next enable.
    public internal(set) var endReason: PrivateCoachingEndReason?
    let makeTransport: TransportFactory
    let makeAudio: AudioFactory
    let speech: any ForegroundCoachingSpeech
    let listenerID: String
    let clock: CoachingClock
    var epoch = UUID()
    var lease: CoachingQualification?
    var transport: (any ForegroundCoachingTransport)?
    var audio: (any ForegroundCoachingAudio)?
    var deadline: ContinuousClock.Instant?
    var cancelHeartbeat: (() -> Void)?
    var cancelRenderExpiry: (() -> Void)?
    var renderTask: Task<Void, Never>?
    var startupInFlight = false
    var retiringJobs = 0
    var rendering = false
    var sequence = 0
    var speechBytes = 0
    var speechFinal = false
    var heartbeatRevision = UUID()
    var renderRevision = UUID()

    public init(listenerID: String, transport: @escaping TransportFactory, audio: @escaping AudioFactory,
                speech: any ForegroundCoachingSpeech, clock: CoachingClock = .init()) throws {
        guard CoachingWireAdvice.identifier(listenerID) else { throw ForegroundCoachingError.invalidListener }
        self.listenerID = listenerID
        makeTransport = transport; makeAudio = audio; self.speech = speech; self.clock = clock
    }

    isolated deinit {
        cancelHeartbeat?(); cancelRenderExpiry?(); renderTask?.cancel()
        speech.cancel(); audio?.stop()
        if let transport { transport.close(); Task { await transport.stop() } }
    }

    /// A trusted local operator confirms awareness every new run. A fresh child and session are mandatory.
    public func enable(participantAwareness: Bool) throws {
        guard status == .off, !startupInFlight else { throw ForegroundCoachingError.busy }
        guard participantAwareness else { throw ForegroundCoachingError.awarenessRequired }
        epoch = UUID(); endReason = nil
        let id = epoch, sessionID = UUID(), destinationID = UUID()
        status = .starting; startupInFlight = true
        defer { startupInFlight = false; finishRetirement() }
        do {
            let child = try makeTransport(ChildHooks(
                advice: { [weak self] in self?.receive($0, epoch: id) },
                ended: { [weak self] in self?.off(epoch: id) }
            ))
            guard starting(id) else { retire(child); throw ForegroundCoachingError.startupLost }
            transport = child
            guard child.send(.enable(sessionID: sessionID, destinationID: destinationID, listenerID: listenerID)),
                  starting(id) else { throw ForegroundCoachingError.transportFailed }
            let owner = try makeAudio(PrivateCoachingSession.Hooks(
                buffer: { [weak self] in self?.forward($0, lease: $1, epoch: id) },
                suspended: { [weak self] _, reason in self?.audioEnded(reason, epoch: id) }
            ))
            let startedAt = clock.now()
            guard starting(id) else { owner.stop(); throw ForegroundCoachingError.startupLost }
            audio = owner
            let runDeadline = startedAt.advanced(by: .seconds(900))
            deadline = runDeadline // Record before begin can activate capture; startup cannot extend it.
            let qualified = try owner.begin(sessionID: sessionID, destinationID: destinationID, consentConfirmed: true)
            guard starting(id) else { throw ForegroundCoachingError.startupLost }
            lease = qualified
            guard child.send(.qualify(qualified)), starting(id) else {
                throw ForegroundCoachingError.transportFailed
            }
            let now = clock.now()
            guard starting(id), lease == qualified, deadline == runDeadline,
                  now < qualified.expiresAt, now < runDeadline else {
                throw ForegroundCoachingError.startupLost
            }
            status = .active
            armHeartbeat(id)
            guard live(id) else { throw ForegroundCoachingError.startupLost }
        } catch { off(epoch: id); throw error }
    }

    /// Disable, participant-awareness loss, profile mutation and permission loss share immediate retirement.
    /// No implicit renewal/restart or retained conversation state survives this boundary.
    public func off() { off(epoch: epoch) }

    /// A local Off reaches here while already retiring, so it records nothing; only an audio-side end is named.
    func audioEnded(_ reason: CoachingSuspension, epoch id: UUID) {
        if epoch == id, status == .starting || status == .active, endReason == nil {
            endReason = PrivateCoachingEndReason(reason)
        }
        off(epoch: id)
    }
}
