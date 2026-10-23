import Foundation
@testable import HailCore
import HailProtocol

/// A playback controller on an injected clock and scheduler, with a fake player, for the #469 idle-watch suites.
@MainActor
final class IdleRig {
    let player = IdlePlayer()
    let controller: ReplyPlaybackController
    private(set) var abandoned = 0
    private var now = ContinuousClock.now
    private struct Timer {
        let due: ContinuousClock.Instant
        let fire: @MainActor () -> Void
        var live = true
    }
    private var timers: [Timer] = []

    var liveDeadlineCount: Int { timers.filter(\.live).count }

    init() {
        controller = ReplyPlaybackController(player: player)
        controller.onStreamAbandoned = { [unowned self] in abandoned += 1 }
        controller.idleNow = { [unowned self] in now }
        controller.idleScheduler = { [unowned self] delay, fire in
            let index = timers.count
            timers.append(Timer(due: now.advanced(by: delay), fire: fire))
            return { [weak self] in self?.timers[index].live = false }
        }
    }

    /// Moves the clock on in 100 ms steps, firing every live timer that comes due on the way.
    func advance(by duration: Duration) {
        let end = now.advanced(by: duration)
        while now < end {
            now = min(end, now.advanced(by: .milliseconds(100)))
            for index in timers.indices where timers[index].live && timers[index].due <= now {
                timers[index].live = false
                timers[index].fire()
            }
        }
    }

    func status(of reply: ReplyDescriptor) -> String? {
        controller.replies.first { $0.id.hasSuffix(reply.id.uuidString.lowercased()) }.map(controller.status(for:))
    }
}

final class IdlePlayer: ReplyAudioPlaying {
    var scheduled: [AudioPayload] = []
    var cancelCount = 0
    private var completions: [@MainActor @Sendable () -> Void] = []

    func schedule(_ payload: AudioPayload, onPlayed: (@MainActor @Sendable () -> Void)?) {
        scheduled.append(payload)
        if let onPlayed { completions.append(onPlayed) }
    }
    func cancel() { cancelCount += 1 }
    func pause() {}
    func resume() {}
    func setMuted(_ muted: Bool) {}
    func replaceQueue(with payloads: [AudioPayload], onPlayed: (@MainActor @Sendable () -> Void)?) {}
    func completeReply() { completions.removeFirst()() }
}

func idleReply() -> ReplyDescriptor {
    ReplyDescriptor(id: UUID(), hostID: "main-mac", targetID: "tmux:codex", audioStreamID: UUID())
}

func idleAudio(_ reply: ReplyDescriptor, sequence: Int, final: Bool, byte: UInt8,
               endpoint: HostEndpoint.Identifier = "main") -> HostReplyEvent {
    var bytes = Data(count: 60_000)
    bytes[0] = byte
    let payload = AudioPayload(
        codec: .pcm16, sampleRate: 24_000, channels: 1, sequence: sequence,
        streamID: reply.audioStreamID, isFinal: final, bytes: bytes, reply: reply
    )
    let frame = Frame(timestamp: Int64(sequence), target: reply.targetID, source: reply.hostID,
                      payload: .audio(payload))
    return HostReplyEvent(endpointID: endpoint, frame: frame)
}

extension IdleRig {
    /// Starts or ends a pause, or an audio-session interruption: it begins on `center` and ends when the session
    /// reports playback resumed.
    func hold(_ kind: String, _ on: Bool, on center: NotificationCenter) {
        if kind == "pause" { return controller.togglePause() }
        guard on else { return controller.noteAudioSession(.interruptionEnded(resumed: true)) }
        center.post(name: ReplyPlaybackController.interruptionNotification, object: nil,
                    userInfo: [ReplyPlaybackController.interruptionTypeKey: UInt(1)])
    }
}
