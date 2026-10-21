#if os(macOS)
import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

/// An ambient request the owner addressed to a route that did not take it (#636, slice 5c), end to end through the
/// listener: nothing is typed, only the device that said it gets one refusal line (when it takes request refusals)
/// and hears "Nothing was sent."; the log has the reason and outcomes only. Synthetic only.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientVoiceRouteRefusalTests {
    static let notSent = AmbientAckClip(pcm: Data(repeating: 9, count: 480), sampleRate: 24_000,
                                        text: "Nothing was sent.")

    /// The stream's target and an offline Deck (no such pane is listed).
    static func routes() throws -> VoiceRoutes {
        try VoiceRoutes(defaultTarget: RecipientTestRig.target, routes: [
            .init(target: RecipientTestRig.target, name: "Scratch"), .init(target: "tmux:deck", name: "Deck")
        ])
    }

    /// Each reason, said by the first of two capable devices on the stream's target: only that device is told.
    @Test(arguments: [
        ("Deck, add a slide.", "not_delivered", "voice route: Deck couldn't take it; nothing was sent"),
        ("Deck.", "nothing_to_say", "voice route: nothing to send to Deck"),
        ("Scratchy, are you there?", "unclear", "voice route: which session? Nothing was sent")
    ])
    func aRefusedRouteSendsNothingAndOnlyTheOwnersDeviceIsTold(
        _ words: String, _ reason: String, _ message: String
    ) async throws {
        let run = try await Self.refused(saying: words, devices: 2, takesRefusals: true)
        let line = Seen.control(.error(code: .voiceRouteRefused, message: message))
        #expect(run.frames == [line, .text("Nothing was sent.")])
        #expect(run.details == ["reason=\(reason) shown=sent confirm=confirmnotsent/0:sent"])
    }

    /// A device that does not take request refusals is told only by the clip: an error would end its connection.
    @Test func anOlderDeviceHearsTheClipButGetsNoLine() async throws {
        let run = try await Self.refused(saying: "Deck, add a slide.", devices: 1, takesRefusals: false)
        #expect(run.frames == [.text("Nothing was sent.")])
        #expect(run.details == ["reason=not_delivered shown=unsupported confirm=confirmnotsent/0:sent"])
    }
}

extension AmbientVoiceRouteRefusalTests {
    enum Seen: Equatable {
        case control(ControlPayload)
        case text(String)
    }

    /// One owner turn on the first device's stream, with `devices` connected to the stream's target. Returns what the
    /// first device received (the line, then the clip's words) and the refusal log; every other device must stay idle,
    /// nothing is typed, and no log names the route or carries the words.
    static func refused(
        saying words: String, devices: Int, takesRefusals: Bool
    ) async throws -> (frames: [Seen], details: [String]) {
        let fake = try FakeRightyo(AmbientWiringVoiceMuteTests.fixture(saying: words, enrolled: true))
        defer { fake.cleanUp() }
        try fake.install(fixture: "enrolled-formed-request.jsonl")
        let details = Mutex<[String]>([])
        let env = try await ambientRig(
            fake, timing: .init(eofGrace: 20, termGrace: 20),
            acknowledgements: AmbientAckLibrary(clips: ["confirmnotsent": [notSent]]), routes: try routes(),
            onEvent: { event in
                if event.event == "ambient_voice_route_refused" { details.withLock { $0.append(event.detail ?? "") } }
            }
        )
        let pair = try await FallbackSocketPair.boundedConnect(
            port: env.port, selecting: Array(repeating: RecipientTestRig.target, count: devices),
            capabilities: takesRefusals ? ["probe", RequestRefusals.capability] : ["probe"]
        )
        defer { pair.close() }
        let stream = UUID()
        try await recipientSocketSend(audio(stream, 0), on: pair.sockets[0])
        var frames: [Seen] = []
        while frames.count < (takesRefusals ? 2 : 1) {
            let frame = try await receiveFrame(on: pair.sockets[0], step: "refusal \(frames.count)")
            switch frame.payload {
            case .control(let control): frames.append(.control(control))
            case .text(let text): frames.append(.text(text.text))
            default: frames.append(.text("unexpected \(frame.payload)"))
            }
        }
        #expect(await eventually { details.withLock { !$0.isEmpty } })
        try await recipientSocketSend(audio(stream, 1, final: true), on: pair.sockets[0])
        await env.router.settle()
        for other in pair.sockets.dropFirst() { try await barrier(on: other, step: "the other device is idle") }
        await env.listener.stop(reason: "synthetic test complete")
        let logged = details.withLock { $0 }
        #expect(logged.allSatisfy { !$0.contains("Deck") && !$0.contains("Scratch") && !$0.contains(words) })
        #expect(await env.rig.adapter.contexts.isEmpty)
        return (frames, logged)
    }
}

/// The refusal's words and frame (#636, slice 5c).
@Suite struct VoiceRouteRefusalMessageTests {
    @Test func theOwnersDeviceIsToldWhyInTapToTalksWords() {
        #expect(RightyoVoiceRouting.Refusal.notDelivered("Deck").message
                == "voice route: Deck couldn't take it; nothing was sent")
        #expect(RightyoVoiceRouting.Refusal.nothingToSay("Deck").message == "voice route: nothing to send to Deck")
        #expect(RightyoVoiceRouting.Refusal.unclear.message == "voice route: which session? Nothing was sent")
        #expect(AmbientStopConfirmation.reserved.contains("confirmnotsent"))
    }

    @Test func onlyADeviceThatTakesRequestRefusalsAndStillListensThereGetsTheLine() async throws {
        let rig = try await VoiceRouteRig.make()
        let line = "voice route: nothing to send to Deck"
        let session = { (capabilities: [String]) async -> HostSession in
            let session = HostSession(host: rig.host, authorizer: PersonalTerminalAuthorizer(), hostName: "mac-test")
            _ = await session.receive(helloFrame(capabilities: capabilities))
            _ = await session.receive(sessionFrame(payload: .control(.select(targetID: VoiceRouteRig.scratch))))
            return session
        }
        let capable = await session(["probe", RequestRefusals.capability])
        let frame = try #require(await capable.routeRefusalFrame(line, target: VoiceRouteRig.scratch))
        #expect(frame.payload == .control(.error(code: .voiceRouteRefused, message: line)))
        #expect(await capable.routeRefusalFrame(line, target: VoiceRouteRig.deck) == nil)
        #expect(await session(["probe"]).routeRefusalFrame(line, target: VoiceRouteRig.scratch) == nil)
        let unready = HostSession(host: rig.host, authorizer: PersonalTerminalAuthorizer(), hostName: "mac-test")
        #expect(await unready.routeRefusalFrame(line, target: VoiceRouteRig.scratch) == nil)
        await rig.listener.stop(reason: "synthetic test complete")
    }
}
#endif
