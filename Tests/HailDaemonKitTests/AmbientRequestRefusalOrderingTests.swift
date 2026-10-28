#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

extension AmbientRequestRefusalTests {
    /// #930's turn ledger, #885/#889's notice ordering and #913's last-moment privacy hold for the dedicated clip.
    @Test(arguments: [false, true])
    func confirmationKeepsItsTurnAndTheDedicatedClipRespectsPrivacy(holdClip: Bool) async throws {
        let scene = try await ConfirmationScene.make(holdClip: holdClip)
        defer { scene.close() }
        let socket = scene.pair.sockets[0]
        try await recipientSocketSend(audio(UUID(), 0), on: socket)
        let first = try await receiveFrame(on: socket, step: "guarded heard turn")
        guard case .control(.ambientHeard(_, _, let turn)) = first.payload else {
            throw TestSupportError.expectedOneControl
        }
        let heardTurn = try #require(turn)
        #expect(await eventually { scene.ack.reached == 1 })
        try await barrier(on: socket, step: "no notice or clip before acknowledgement")
        scene.ack.open()
        try await scene.checkNotice(turn: heardTurn)
        try await scene.checkClip(held: holdClip)
        #expect(await eventually { scene.log.details("ambient_request_refused").count == 1 })
        let outcome = holdClip ? "suppressed_privacy" : "confirmneedsconfirmation/0:sent"
        #expect(scene.log.details("ambient_request_refused")
                == ["reason=confirmation_required rules=sudo shown=sent confirm=\(outcome)"])
        try await barrier(on: socket, step: "exactly one notice and no extra confirmation frames")
        #expect(scene.log.allDetails.allSatisfy {
            !$0.contains(heardTurn.uuidString) && !$0.contains("SYNTHETIC")
        })
        await scene.env.listener.stop(reason: "synthetic test complete")
    }
}

private struct ConfirmationScene {
    static let dedicated = AmbientAckClip(pcm: Data(repeating: 3, count: 480), sampleRate: 12_000,
                                          text: "That needs confirmation.")
    let fake: FakeRightyo
    let env: AmbientWiringRig
    let pair: FallbackSocketPair
    let ack: ClipGate
    let clip: ClipGate
    let log: AmbientEventDetails

    static func make(holdClip: Bool) async throws -> Self {
        let fake = try FakeRightyo("""
        /usr/bin/sed -n '1,4p' events.jsonl | /usr/bin/sed "s/tool-demo/$7/g"
        /bin/cat > /dev/null
        /usr/bin/sed -n -e '$p' events.jsonl | /usr/bin/sed "s/tool-demo/$7/g"
        """)
        try AmbientRequestRefusalTests.fixture().write(
            to: fake.directory.appendingPathComponent("events.jsonl"), atomically: true, encoding: .utf8
        )
        let ack = ClipGate(), clip = ClipGate(), log = AmbientEventDetails()
        let library = AmbientAckLibrary(clips: ["default": [PendingInputRun.ack],
                                                AmbientStopConfirmation.needsConfirmation: [dedicated]])
        let env = try await ambientRig(
            fake, timing: .init(eofGrace: 20, termGrace: 2), acknowledgements: library,
            guardPatterns: DangerousPatternGuard.defaults, acknowledgementHold: ack.acknowledgement,
            notSentPlaying: holdClip ? clip.playing : nil, onEvent: { log.record($0) }
        )
        let pair = try await FallbackSocketPair.boundedConnect(
            port: env.port, selecting: [RecipientTestRig.target], capabilities: HeardTurnRig.capabilities
        )
        return Self(fake: fake, env: env, pair: pair, ack: ack, clip: clip, log: log)
    }

    func checkNotice(turn: UUID) async throws {
        let socket = pair.sockets[0]
        let words = try await receiveFrame(on: socket, step: "acknowledgement text")
        let pcm = try await receiveFrame(on: socket, step: "acknowledgement audio")
        guard case .text(let text) = words.payload, case .audio(let audio) = pcm.payload else {
            throw TestSupportError.expectedOneControl
        }
        #expect(text.text == PendingInputRun.ack.text && audio.bytes == PendingInputRun.ack.pcm)
        let refusal = try await receiveFrame(on: socket, step: "correlated guard refusal")
        #expect(refusal.payload == .control(.error(code: .voiceRouteRefused,
            message: "request requires confirmation at the Mac; nothing was sent", turn: turn)))
    }

    func checkClip(held: Bool) async throws {
        if held {
            #expect(await eventually { clip.reached == 1 })
            let connection = try #require(await env.listener.heardTurnConnections().first)
            let hold = await env.listener.replyHold
            env.router.state.withLock { state in
                state.duck[connection] = AmbientDuckTimer(token: UUID(), timer: nil)
                hold.set(true, connection: connection)
            }
            clip.open()
        } else {
            let words = try await receiveFrame(on: pair.sockets[0], step: "dedicated confirmation text")
            let pcm = try await receiveFrame(on: pair.sockets[0], step: "dedicated confirmation audio")
            guard case .text(let text) = words.payload, case .audio(let audio) = pcm.payload else {
                throw TestSupportError.expectedOneControl
            }
            #expect(text.text == Self.dedicated.text && audio.bytes == Self.dedicated.pcm)
        }
    }

    func close() {
        ack.open()
        clip.open()
        pair.close()
        fake.cleanUp()
    }
}
#endif
