#if os(macOS)
import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

/// Instant acknowledgement through the real listener (rightyo#105, #324): an admitted ambient request plays its
/// persona's clip on the phone that heard it, as a request-less reply, and is logged with tokens only.
@Suite(.serialized, .timeLimit(.minutes(1))) struct AmbientWiringAckTests {
    static let clip = AmbientAckClip(pcm: Data(repeating: 1, count: 480), sampleRate: 24_000, text: "On it.")

    @Test func anAdmittedRequestPlaysThePersonasClipOnTheOriginatingPhone() async throws {
        let details = try await run(clips: ["rightyo": [Self.clip]]) { socket in
            let text = try await recipientSocketReceive(on: socket)
            let audio = try await recipientSocketReceive(on: socket)
            guard case .text(let words) = text.payload, case .audio(let clip) = audio.payload else {
                Issue.record("expected the clip's words, then the clip")
                return
            }
            #expect(words.text == "On it.")
            #expect(words.reply?.requestID == nil)
            #expect(clip.bytes == Self.clip.pcm)
            #expect(clip.isFinal && clip.sequence == 0)
            #expect(clip.reply == words.reply)
            #expect(text.source == "mac-test" && text.target == RecipientTestRig.target)
        }
        let ack = try #require(details.first { $0.hasPrefix("persona=") })
        #expect(ack.hasPrefix("persona=rightyo clip=0 rightyo_ms=100 host_ms="))
        #expect(ack.hasSuffix(" outcome=sent"))
    }

    @Test func theDefaultFolderVoicesAnUnclippedPersona() async throws {
        let details = try await run(clips: ["default": [Self.clip]]) { socket in
            _ = try await recipientSocketReceive(on: socket)
            _ = try await recipientSocketReceive(on: socket)
        }
        #expect(details.contains { $0.hasPrefix("persona=default clip=0 ") && $0.hasSuffix(" outcome=sent") })
    }

    @Test func withoutClipsNothingIsSentAndTheSkipIsLogged() async throws {
        let details = try await run(clips: ["jarvis": [Self.clip]]) { socket in
            try await recipientSocketBarrier(on: socket)
        }
        #expect(details.contains("outcome=skipped reason=no_clips"))
    }

    /// Starts one ambient stream from the phone, lets the fixture's request through, checks the phone's socket,
    /// then ends the stream and returns every `ambient_acknowledged` detail.
    private func run(
        clips: [String: [AmbientAckClip]], check: (URLSessionWebSocketTask) async throws -> Void
    ) async throws -> [String] {
        let fake = try FakeRightyo(AmbientAcknowledgementTests.fixtureWithNames)
        defer { fake.cleanUp() }
        try fake.install(fixture: "tool-events.jsonl")
        let details = Mutex<[String]>([])
        let env = try await ambientRig(
            fake, timing: .init(eofGrace: 20, termGrace: 20), acknowledgements: AmbientAckLibrary(clips: clips),
            onEvent: { event in
                if event.event == "ambient_acknowledged" { details.withLock { $0.append(event.detail ?? "") } }
            }
        )
        let pair = try await FallbackSocketPair.connect(port: env.port, selecting: [RecipientTestRig.target])
        defer { pair.close() }
        let stream = UUID()
        try await recipientSocketSend(audio(stream, 0), on: pair.sockets[0])
        #expect(await eventually { details.withLock { !$0.isEmpty } })
        try await check(pair.sockets[0])
        try await recipientSocketSend(audio(stream, 1, final: true), on: pair.sockets[0])
        await env.router.settle()
        await env.listener.stop(reason: "synthetic test complete")
        return details.withLock { $0 }
    }
}
#endif
