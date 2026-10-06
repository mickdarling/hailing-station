import Foundation
import HailProtocol
import Testing
@testable import HailCore

/// #282: a background `playback_failed` on device needs the underlying error to be diagnosable.
@MainActor
@Test func aSchedulingFailureKeepsItsDomainAndCodeForDiagnostics() {
    let controller = ReplyPlaybackController(player: FailingReplyPlayer())
    let reply = ReplyDescriptor(id: UUID(), hostID: "main-mac", targetID: "tmux:codex", audioStreamID: UUID())
    let audio = AudioPayload(codec: .pcm16, sampleRate: 24_000, channels: 1, sequence: 0,
                             streamID: reply.audioStreamID, isFinal: true, bytes: Data([1, 0]), reply: reply)
    controller.ingest(HostReplyEvent(endpointID: "main", frame: Frame(
        timestamp: 0, target: reply.targetID, source: reply.hostID, payload: .audio(audio))))
    #expect(controller.lastPlaybackError?.domain == NSOSStatusErrorDomain)
    #expect(controller.lastPlaybackError?.code == 561_017_449) // '!pla'
    #expect(DeviceDiagnostics.errorDomain(NSOSStatusErrorDomain) == "coreaudio")
    #expect(DeviceDiagnostics.errorDomain("com.example") == "other")
}

@MainActor
private final class FailingReplyPlayer: ReplyAudioPlaying {
    func schedule(_ payload: AudioPayload, onPlayed: (@MainActor @Sendable () -> Void)?) throws {
        throw NSError(domain: NSOSStatusErrorDomain, code: 561_017_449)
    }
    func cancel() {}
    func pause() {}
    func resume() {}
    func setMuted(_ muted: Bool) {}
    func replaceQueue(with payloads: [AudioPayload], onPlayed: (@MainActor @Sendable () -> Void)?) {}
}
