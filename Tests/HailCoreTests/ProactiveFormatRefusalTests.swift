import Foundation
import HailProtocol
import Testing
@testable import HailCore

@MainActor
@Suite struct ProactiveFormatRefusalTests {
    @Test(arguments: [HailProtocol.AudioCodec.opus, .pcm16])
    func refusedInitialFormatsCannotExhaustProactiveSpeech(_ codec: HailProtocol.AudioCodec) throws {
        let rig = ProactivePlaybackRig()
        for _ in 0...ProactiveReplyPlaybackState.limit {
            rig.ingest(rig.audio(codec: codec, channels: codec == .pcm16 ? 2 : 1))
        }
        #expect(rig.controller.queue.isEmpty)
        try rig.makeQuiet()
        rig.ingest(rig.audio(byte: 2))
        #expect(rig.player.scheduled.map(\.bytes.first) == [2])
    }

    @Test func rejectedFormatCannotBecomeOrdinaryAudio() throws {
        let rig = ProactivePlaybackRig()
        let rejected = rig.audio(codec: .opus)
        rig.ingest(rejected)
        var frame = rejected.frame
        frame.id = UUID()
        var audio = try #require(frame.audioPayload)
        var descriptor = try #require(audio.reply)
        descriptor.sessionUpdateID = nil
        descriptor.priority = .normal
        audio.reply = descriptor
        audio.codec = .pcm16
        frame.payload = .audio(audio)
        try rig.makeQuiet()
        rig.ingest(HostReplyEvent(endpointID: rejected.endpointID, frame: frame))
        #expect(rig.player.scheduled.isEmpty && rig.controller.queue.isEmpty)
    }

    @Test func unsupportedDuplicateDoesNotRetireAcceptedProactiveAudio() throws {
        let rig = ProactivePlaybackRig()
        try rig.makeQuiet()
        let accepted = rig.audio()
        rig.ingest(accepted)
        var frame = accepted.frame
        frame.id = UUID()
        var audio = try #require(frame.audioPayload)
        audio.codec = .opus
        frame.payload = .audio(audio)
        rig.ingest(HostReplyEvent(endpointID: accepted.endpointID, frame: frame))
        #expect(rig.player.cancelCount == 0)
        #expect(rig.player.scheduled.count == 1 && rig.controller.queue.count == 1)
    }
}

private extension Frame {
    var audioPayload: AudioPayload? {
        guard case .audio(let payload) = self.payload else { return nil }
        return payload
    }
}
