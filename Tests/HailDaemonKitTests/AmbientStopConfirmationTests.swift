#if os(macOS)
import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

/// The owner's spoken stop is confirmed out loud (#418): a host clip, after the stop, on the connection that said
/// stop, through the acknowledgement path. Synthetic only; not device hearing.
@Suite(.serialized, .timeLimit(.minutes(1))) struct AmbientStopConfirmationTests {
    static let stopped = AmbientAckClip(pcm: Data(repeating: 2, count: 480), sampleRate: 24_000, text: "Stopped.")
    static let idle = AmbientAckClip(pcm: Data(repeating: 3, count: 480), sampleRate: 24_000,
                                     text: "Nothing playing, standing by.")

    private func receipt(owner: Bool, scope: [String] = ["playback", "pending_request"]) -> RightyoDismissReceipt {
        RightyoDismissReceipt(reason: "stop-phrase", scope: scope, withdrawn: 0, alreadyDelivered: 0, owner: owner)
    }

    @Test func onlyTheOwnersPlaybackStopOnALiveConnectionIsConfirmed() {
        typealias Confirm = AmbientStopConfirmation
        #expect(Confirm.persona(for: receipt(owner: true), playback: "stopped") == Confirm.stopped)
        #expect(Confirm.persona(for: receipt(owner: true), playback: "cut") == Confirm.stopped)
        #expect(Confirm.persona(for: receipt(owner: true), playback: "idle") == Confirm.idle)
        #expect(Confirm.persona(for: receipt(owner: false), playback: "stopped") == nil)
        #expect(Confirm.persona(for: receipt(owner: true), playback: "no_connection") == nil)
        #expect(Confirm.persona(for: receipt(owner: true, scope: ["engagement"]), playback: "none") == nil)
    }

    @Test func theFoldersAreReservedKeysAndAnIdleStopFallsBackToStopped() throws {
        #expect(AmbientStopConfirmation.stopped == "confirmstopped")
        #expect(AmbientStopConfirmation.idle == "confirmidle")
        let both = AmbientAckLibrary(clips: ["confirmstopped": [Self.stopped], "confirmidle": [Self.idle]])
        #expect(AmbientStopConfirmation.clip("confirmidle", in: both)?.clip == Self.idle)
        let stoppedOnly = AmbientAckLibrary(clips: ["confirmstopped": [Self.stopped]])
        let fallback = try #require(AmbientStopConfirmation.clip("confirmidle", in: stoppedOnly))
        #expect(fallback.persona == "confirmstopped" && fallback.clip == Self.stopped)
        #expect(AmbientStopConfirmation.clip("confirmstopped", in: AmbientAckLibrary(clips: [:])) == nil)
    }

    /// The dismissal fixture under an enrolled session, its `dismiss` from the owner.
    static let ownerFixture = """
        /usr/bin/sed -e '$d' -e "s/dismissal-demo/$7/g" -e 's/"speakers": "anonymous"/"speakers": "enrolled"/' \
          -e 's/"scope": \\["playback"/"role": "owner", "scope": ["playback"/' events.jsonl
        /bin/cat > /dev/null
        /usr/bin/sed -n -e '$p' events.jsonl | /usr/bin/sed "s/dismissal-demo/$7/g"
        """

    @Test func theOwnersStopIsConfirmedOnTheConnectionThatSaidIt() async throws {
        let details = try await run(fixture: Self.ownerFixture) { socket in
            let text = try await receiveFrame(on: socket, step: "confirmation words")
            let audio = try await receiveFrame(on: socket, step: "confirmation clip")
            guard case .text(let words) = text.payload, case .audio(let clip) = audio.payload else {
                Issue.record("expected the confirmation's words, then its clip")
                return
            }
            // Nothing was in flight on the host, so the idle wording plays.
            #expect(words.text == "Nothing playing, standing by.")
            #expect(words.reply?.requestID == nil)
            #expect(clip.bytes == Self.idle.pcm && clip.reply == words.reply)
            #expect(text.source == "mac-test" && text.target == RecipientTestRig.target)
        }
        #expect(details == ["clip=confirmidle/0 outcome=sent"])
    }

    @Test func anotherSpeakersStopPlaysNothing() async throws {
        let details = try await run(fixture: AmbientWiringDismissTests.fixtureUntilEOF) { socket in
            try await recipientSocketBarrier(on: socket)
        }
        #expect(details.isEmpty)
    }

    /// One ambient stream through the dismissal fixture with confirmation clips loaded; returns every
    /// `ambient_stop_confirmed` detail once `ambient_dismissed` has been logged and `check` has run.
    private func run(fixture: String, check: (URLSessionWebSocketTask) async throws -> Void) async throws -> [String] {
        let fake = try FakeRightyo(fixture)
        defer { fake.cleanUp() }
        try fake.install(fixture: "dismissal-events.jsonl")
        let details = Mutex<[String]>([]), dismissed = Mutex(false)
        let library = AmbientAckLibrary(clips: ["confirmstopped": [Self.stopped], "confirmidle": [Self.idle]])
        let env = try await ambientRig(
            fake, timing: .init(eofGrace: 20, termGrace: 20), acknowledgements: library,
            onEvent: { event in
                if event.event == "ambient_stop_confirmed" { details.withLock { $0.append(event.detail ?? "") } }
                if event.event == "ambient_dismissed" { dismissed.withLock { $0 = true } }
            }
        )
        let pair = try await FallbackSocketPair.connect(port: env.port, selecting: [RecipientTestRig.target])
        defer { pair.close() }
        let stream = UUID()
        try await recipientSocketSend(audio(stream, 0), on: pair.sockets[0])
        #expect(await eventually { dismissed.withLock { $0 } })
        try await check(pair.sockets[0])
        try await recipientSocketSend(audio(stream, 1, final: true), on: pair.sockets[0])
        await env.router.settle()
        await env.listener.stop(reason: "synthetic test complete")
        return details.withLock { $0 }
    }
}
#endif
