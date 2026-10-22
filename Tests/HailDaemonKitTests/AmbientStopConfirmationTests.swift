#if os(macOS)
import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

/// The owner's spoken stop is confirmed out loud (#418): a host clip, after the stop, on the connection that said
/// stop, through the acknowledgement path. Synthetic only; not device hearing.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientWiringStopConfirmationTests {
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
        #expect(Confirm.skipReason(for: receipt(owner: false), playback: "stopped") == "not_owner")
        #expect(Confirm.persona(for: receipt(owner: true), playback: "no_connection") == nil)
        #expect(Confirm.skipReason(for: receipt(owner: true), playback: "no_connection") == "no_connection")
        #expect(Confirm.persona(for: receipt(owner: true, scope: ["engagement"]), playback: "none") == nil)
    }

    @Test func reservedFoldersAreNeverAnAcknowledgementVoiceAndAnIdleStopFallsBackToStopped() throws {
        #expect(AmbientStopConfirmation.reserved == Self.reserved)
        let both = AmbientAckLibrary(clips: ["confirmstopped": [Self.stopped], "confirmidle": [Self.idle],
                                             "jarvis": [Self.stopped]])
        #expect(Set(both.clips.keys) == ["jarvis"])
        #expect(both.next(for: "confirmstopped") == nil)
        #expect(AmbientStopConfirmation.clip("confirmidle", in: both)?.clip == Self.idle)
        let stoppedOnly = AmbientAckLibrary(clips: ["confirmstopped": [Self.stopped]])
        let fallback = try #require(AmbientStopConfirmation.clip("confirmidle", in: stoppedOnly))
        #expect(fallback.persona == "confirmstopped" && fallback.clip == Self.stopped)
        #expect(AmbientStopConfirmation.clip("confirmstopped", in: AmbientAckLibrary(clips: [:])) == nil)
    }

    /// The reserved folders load outside the persona cap: eight user folders, sorting before and after them, all load.
    @Test func reservedFoldersNeverPushAUserFolderOut() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("acks-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let users = ["a1", "a2", "a3", "a4", "p1", "p2", "p3", "p4"]
        for folder in users + ["confirm-stopped", "confirm-idle"] {
            let url = root.appendingPathComponent(folder)
            try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
            try AmbientWiringAcknowledgementTests.wav(samples: 240).write(to: url.appendingPathComponent("clip.wav"))
        }
        let library = AmbientAckLibrary(directory: root)
        #expect(Set(library.clips.keys) == Set(users))
        #expect(library.nextReserved("confirmstopped") != nil && library.nextReserved("confirmidle") != nil)
    }

    @Test func aSentHostPhraseHeardBackWordForWordIsEchoHoweverShort() {
        let clock = Mutex(ContinuousClock.now)
        let phrases = HostPhrases(now: { clock.withLock { $0 } })
        phrases.observe(Self.stopped, outcome: "sent")
        #expect(phrases.isEcho("stopped"))
        #expect(!phrases.isEcho("stopped, now go on"))
        #expect(!phrases.isEcho("stop"))
        clock.withLock { $0 = $0.advanced(by: RecentSpokenReplies.hold + .seconds(1)) }
        #expect(!phrases.isEcho("stopped"))
    }

    /// A clip that was not delivered was never heard, so its words are never held as echo.
    @Test(arguments: ["no_connection", "not_ready", "refused"])
    func anUndeliveredHostPhraseIsNeverEcho(outcome: String) {
        let phrases = HostPhrases()
        phrases.observe(Self.stopped, outcome: outcome)
        #expect(!phrases.isEcho("stopped"))
    }

    /// The dismissal fixture under an enrolled session, its `dismiss` and the transcript it cites with these roles.
    static func fixture(dismiss: String, turn: String) -> String {
        """
        /usr/bin/sed -e '$d' -e "s/dismissal-demo/$7/g" -e 's/"speakers": "anonymous"/"speakers": "enrolled"/' \
          -e 's/"scope": \\["playback"/"role": "\(dismiss)", "scope": ["playback"/' \
          -e 's/"utterance_id": "dismissal", "revision"/"utterance_id": "dismissal", "role": "\(turn)", "revision"/' \
          events.jsonl
        /bin/cat > /dev/null
        /usr/bin/sed -n -e '$p' events.jsonl | /usr/bin/sed "s/dismissal-demo/$7/g"
        """
    }

    @Test func theOwnersStopIsConfirmedOnTheConnectionThatSaidIt() async throws {
        let details = try await run(fixture: Self.fixture(dismiss: "owner", turn: "owner")) { socket in
            let text = try await receiveFrame(on: socket, step: "confirmation words")
            let audio = try await receiveFrame(on: socket, step: "confirmation clip")
            guard case .text(let words) = text.payload, case .audio(let clip) = audio.payload else {
                Issue.record("expected the confirmation's words, then its clip")
                return
            }
            // Nothing was in flight and the device takes no stop_playback, so the idle wording plays.
            #expect(words.text == "Nothing playing, standing by.")
            #expect(words.reply?.requestID == nil)
            #expect(clip.bytes == Self.idle.pcm && clip.reply == words.reply)
            #expect(text.source == "mac-test" && text.target == RecipientTestRig.target)
        }
        #expect(details == ["clip=confirmidle/0 outcome=sent"])
    }

    @Test func aCapableDeviceGetsTheStopFirstThenStopped() async throws {
        let fixture = Self.fixture(dismiss: "owner", turn: "owner")
        let details = try await run(fixture: fixture, capabilities: [PlaybackStop.capability]) { socket in
            #expect(try await receiveFrame(on: socket, step: "stop").payload == .control(.stopPlayback))
            let text = try await receiveFrame(on: socket, step: "confirmation words")
            guard case .text(let words) = text.payload else {
                Issue.record("expected the confirmation's words after the stop")
                return
            }
            #expect(words.text == "Stopped.")
            _ = try await receiveFrame(on: socket, step: "confirmation clip")
        } after: { router in
            // Sent, so its words are now the host's own echo.
            #expect(router.hostPhrases.isEcho("Stopped"))
        }
        #expect(details == ["clip=confirmstopped/0 outcome=sent"])
    }

    @Test(arguments: [
        ("anonymous session", AmbientWiringDismissTests.fixtureUntilEOF),
        ("enrolled participant", fixture(dismiss: "participant", turn: "participant")),
        ("owner dismiss citing a participant turn", fixture(dismiss: "owner", turn: "participant"))
    ])
    func anyOtherStopPlaysNothing(_ name: String, _ fixture: String) async throws {
        let details = try await run(fixture: fixture) { try await barrier(on: $0, step: "nothing played") }
        #expect(details == ["outcome=skipped reason=not_owner"], "\(name)")
    }

    /// One ambient stream through the dismissal fixture with confirmation clips loaded, from a plain device or one
    /// advertising `capabilities`; waits for the confirmation's own log line, runs `check`, then returns every
    /// `ambient_stop_confirmed` detail.
    private func run(
        fixture: String, capabilities: [String]? = nil, check: (URLSessionWebSocketTask) async throws -> Void,
        after: (AmbientRightyoRouter) -> Void = { _ in }
    ) async throws -> [String] {
        let fake = try FakeRightyo(fixture)
        defer { fake.cleanUp() }
        try fake.install(fixture: "dismissal-events.jsonl")
        let details = Mutex<[String]>([])
        let library = AmbientAckLibrary(clips: ["confirmstopped": [Self.stopped], "confirmidle": [Self.idle]])
        let env = try await ambientRig(
            fake, timing: .init(eofGrace: 20, termGrace: 20), acknowledgements: library,
            onEvent: { event in
                if event.event == "ambient_stop_confirmed" { details.withLock { $0.append(event.detail ?? "") } }
            }
        )
        let (session, socket) = try await device(port: env.port, capabilities: capabilities ?? ["probe"])
        defer {
            socket.cancel(with: .normalClosure, reason: nil)
            session.invalidateAndCancel()
        }
        let stream = UUID()
        try await recipientSocketSend(audio(stream, 0), on: socket)
        #expect(await eventually { details.withLock { !$0.isEmpty } })
        try await check(socket)
        after(env.router)
        try await recipientSocketSend(audio(stream, 1, final: true), on: socket)
        await env.router.settle()
        await env.listener.stop(reason: "synthetic test complete")
        return details.withLock { $0 }
    }

    /// A negotiated loopback device selecting the rig's target, advertising `capabilities`.
    private func device(port: UInt16, capabilities: [String]) async throws -> (URLSession, URLSessionWebSocketTask) {
        let (session, socket) = try recipientSocket(port: port)
        try await recipientSocketSend(sessionFrame(payload: .control(.hello(HelloInfo(
            versions: [1], capabilities: capabilities, deviceName: "test"
        )))), on: socket)
        _ = try await receiveFrame(on: socket, step: "host hello")
        try await recipientSocketSend(
            sessionFrame(payload: .control(.select(targetID: RecipientTestRig.target))), on: socket
        )
        try await barrier(on: socket, step: "selection")
        return (session, socket)
    }
}

extension AmbientWiringStopConfirmationTests {
    /// Stop (#418), mute (#404), media mode (#551), spoken notes (#552), route refusals (#636) and duck mode (#735).
    static let reserved: Set<String> = ["confirmstopped", "confirmidle", "confirmmuted", "confirmunmuted",
                                        "confirmmediaon", "confirmmediaoff", "confirmsaved", "confirmnotsaved",
                                        "confirmnotsent", "confirmduckon", "confirmduckoff"]
}
#endif
