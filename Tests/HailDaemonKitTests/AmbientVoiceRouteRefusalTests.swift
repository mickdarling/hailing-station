#if os(macOS)
import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

/// An ambient request the owner addressed to a route that did not take it (#636, slice 5c), end to end through the
/// listener: nothing is typed, the device that said it gets one refusal line when it takes request refusals, and
/// hears "Nothing was sent."; the log has the reason and outcomes only. Synthetic only.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientVoiceRouteRefusalTests {
    static let notSent = AmbientAckClip(pcm: Data(repeating: 9, count: 480), sampleRate: 24_000,
                                        text: "Nothing was sent.")
    static let line = FramePayload.control(.error(code: .voiceRouteRefused,
                                                  message: "voice route: Deck couldn't take it; nothing was sent"))

    /// The stream's target and an offline Deck (no such pane is listed).
    static func routes() throws -> VoiceRoutes {
        try VoiceRoutes(defaultTarget: RecipientTestRig.target, routes: [
            .init(target: RecipientTestRig.target, name: "Scratch"), .init(target: "tmux:deck", name: "Deck")
        ])
    }

    @Test(arguments: [true, false])
    func anOfflineRouteSendsNothingAndTheOwnerIsTold(_ takesRefusals: Bool) async throws {
        let fake = try FakeRightyo(AmbientWiringVoiceMuteTests.fixture(saying: "Deck, add a slide.", enrolled: true))
        defer { fake.cleanUp() }
        try fake.install(fixture: "enrolled-formed-request.jsonl")
        let details = Mutex<[String]>([])
        let env = try await ambientRig(
            fake, timing: .init(eofGrace: 20, termGrace: 20),
            acknowledgements: AmbientAckLibrary(clips: ["confirmnotsent": [Self.notSent]]), routes: try Self.routes(),
            onEvent: { event in
                if event.event == "ambient_voice_route_refused" { details.withLock { $0.append(event.detail ?? "") } }
            }
        )
        let pair = try await FallbackSocketPair.boundedConnect(
            port: env.port, selecting: [RecipientTestRig.target],
            capabilities: takesRefusals ? ["probe", RequestRefusals.capability] : ["probe"]
        )
        defer { pair.close() }
        let stream = UUID()
        try await recipientSocketSend(audio(stream, 0), on: pair.sockets[0])
        if takesRefusals {
            #expect(try await receiveFrame(on: pair.sockets[0], step: "refusal line").payload == Self.line)
        }
        let clip = try await receiveFrame(on: pair.sockets[0], step: "not-sent clip")
        guard case .text(let words) = clip.payload else {
            Issue.record("expected the not-sent clip, got \(clip.payload)")
            return
        }
        #expect(words.text == "Nothing was sent.")
        #expect(await eventually { details.withLock { !$0.isEmpty } })
        try await recipientSocketSend(audio(stream, 1, final: true), on: pair.sockets[0])
        await env.router.settle()
        await env.listener.stop(reason: "synthetic test complete")
        let shown = takesRefusals ? "sent" : "unsupported"
        #expect(details.withLock { $0 } == ["reason=not_delivered shown=\(shown) confirm=confirmnotsent/0:sent"])
        #expect(details.withLock { $0 }.allSatisfy { !$0.contains("Deck") && !$0.contains("slide") })
        #expect(await env.rig.adapter.contexts.isEmpty)
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

    @Test func onlyADeviceThatTakesRequestRefusalsGetsTheLine() async throws {
        let rig = try await VoiceRouteRig.make()
        let capable = HostSession(host: rig.host, authorizer: PersonalTerminalAuthorizer(), hostName: "mac-test")
        _ = await capable.receive(helloFrame(capabilities: ["probe", RequestRefusals.capability]))
        let frame = try #require(await capable.routeRefusalFrame("voice route: nothing to send to Deck"))
        #expect(frame.payload
                == .control(.error(code: .voiceRouteRefused, message: "voice route: nothing to send to Deck")))
        let older = HostSession(host: rig.host, authorizer: PersonalTerminalAuthorizer(), hostName: "mac-test")
        _ = await older.receive(helloFrame(capabilities: ["probe"]))
        #expect(await older.routeRefusalFrame("voice route: nothing to send to Deck") == nil)
        let unready = HostSession(host: rig.host, authorizer: PersonalTerminalAuthorizer(), hostName: "mac-test")
        #expect(await unready.routeRefusalFrame("voice route: nothing to send to Deck") == nil)
        await rig.listener.stop(reason: "synthetic test complete")
    }
}
#endif
