#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// Exercise makePipeline's actual callback wiring with a started, prebound non-configured target.
extension AmbientRouterStreamTargetTests {
    enum BoundConfirmation: CaseIterable {
        case stop, mute, media, note, ack, heard, overheard, routeRefusal, notSent

        var script: String {
            switch self {
            case .stop: AmbientWiringStopConfirmationTests.fixture(dismiss: "owner", turn: "owner")
            case .heard, .overheard, .ack: AmbientWiringAcknowledgementTests.fixtureWithNames
            default: AmbientWiringVoiceMuteTests.fixture(saying: phrase, enrolled: true)
            }
        }
        var fixture: String {
            switch self {
            case .stop: "dismissal-events.jsonl"
            case .heard, .overheard, .ack: "tool-events.jsonl"
            default: "enrolled-formed-request.jsonl"
            }
        }
        var phrase: String {
            switch self {
            case .mute: "Rightyo, mute."
            case .media: "Rightyo, media mode."
            case .note: "Rightyo, add to Notes: buy milk."
            case .routeRefusal: "Deck."
            default: "Rightyo, check the plan."
            }
        }
        var expected: String {
            switch self {
            case .stop: "Nothing playing, standing by."
            case .mute: "Stopped."
            case .media: "Media mode on."
            case .note: "Saved."
            case .routeRefusal, .notSent: "Nothing was sent."
            default: "On it."
            }
        }
    }

    @Test(arguments: BoundConfirmation.allCases)
    func everyConfirmationUsesTheStartedPreboundTarget(_ kind: BoundConfirmation) async throws {
        let fake = try FakeRightyo(kind.script)
        defer { fake.cleanUp() }
        try fake.install(fixture: kind.fixture)
        let inbox = fake.directory.appendingPathComponent("Inbox.md")
        let env = try await preboundAmbientRig(
            fake, timing: .init(eofGrace: 20, termGrace: 0.1), acknowledgements: boundClips(kind),
            destinations: try VoiceDestinations(["Notes": .markdown(inbox.path)]),
            routes: kind == .routeRefusal ? try AmbientVoiceRouteRefusalTests.routes() : nil
        )
        if kind == .notSent { await env.rig.adapter.failHandoff(with: AdapterError.inputPending(reason: .staleInput)) }
        let capabilities = ["probe", AmbientHeard.capability, AmbientOverheard.capability, RequestRefusals.capability]
        let pair = try await FallbackSocketPair.boundedConnect(
            port: env.port, selecting: [RecipientTestRig.target], capabilities: capabilities)
        defer { pair.close() }
        let socket = pair.sockets[0], stream = UUID()
        if kind == .overheard {
            try await recipientSocketSend(sessionFrame(payload: .control(.overheardScope(scope: "everyone"))),
                                          on: socket)
            try await barrier(on: socket, step: "overheard scope")
        }
        try await recipientSocketSend(audio(stream, 0), on: socket)
        try #require(await eventually { env.router.activeStream == stream })
        #expect(env.router.state.withLock {
            $0.active?.target == RecipientTestRig.target && $0.active?.binding == "reply-binding"
        })
        #expect(env.router.configuration.target != RecipientTestRig.target)
        try await checkBoundFrames(kind, socket: socket)
        if kind == .note {
            #expect(try String(contentsOf: inbox, encoding: .utf8).hasSuffix(" buy milk.\n"))
        }
        try await recipientSocketSend(audio(stream, 1, final: true), on: socket)
        await boundedSettle(env.router)
        await env.listener.stop()
    }

    private func boundClips(_ kind: BoundConfirmation) -> AmbientAckLibrary {
        let clip = AmbientAckClip(pcm: Data(repeating: 1, count: 480), sampleRate: 24_000, text: kind.expected)
        let ack = AmbientAckClip(pcm: Data(repeating: 2, count: 480), sampleRate: 24_000, text: "On it.")
        let folders = ["rightyo", "confirmstopped", "confirmidle", "confirmmediaon", "confirmsaved", "confirmnotsent"]
        return AmbientAckLibrary(clips: Dictionary(uniqueKeysWithValues: folders.map {
            ($0, [$0 == "rightyo" ? ack : clip])
        }))
    }

    private struct BoundFrames {
        var heard = false, overheard = false, refused = false, words = false, audio = false
        mutating func observe(_ frame: Frame, expected: String) {
            switch frame.payload {
            case .control(.ambientHeard(let target, _, _)):
                #expect(target == RecipientTestRig.target)
                heard = true
            case .control(.ambientOverheard(let target, _, _, _)):
                #expect(target == RecipientTestRig.target)
                overheard = true
            case .control(.error(let code, _, _)):
                #expect(code == .voiceRouteRefused)
                // Control errors carry no frame target; showRouteRefusal checks the explicit source target.
                refused = true
            case .text(let text):
                #expect(frame.target == RecipientTestRig.target)
                if text.text == expected { words = true }
            case .audio:
                #expect(frame.target == RecipientTestRig.target)
                if words { audio = true }
            default: Issue.record("unexpected confirmation payload")
            }
        }
        func check(_ kind: BoundConfirmation) {
            if kind == .heard { #expect(heard) }
            if kind == .overheard { #expect(heard && overheard) }
            if kind == .routeRefusal || kind == .notSent { #expect(refused) }
        }
    }
    private func checkBoundFrames(_ kind: BoundConfirmation, socket: URLSessionWebSocketTask) async throws {
        var seen = BoundFrames()
        // The normal request may emit heard + ack before a delivery refusal and its not-sent clip.
        for _ in 0..<10 {
            let frame = try await receiveFrame(on: socket, step: "prebound \(kind) confirmation")
            seen.observe(frame, expected: kind.expected)
            if seen.words && seen.audio {
                seen.check(kind)
                return
            }
        }
        Issue.record("missing prebound target confirmation")
    }
}
#endif
