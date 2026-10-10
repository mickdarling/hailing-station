#if os(macOS)
import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

/// The user's own ambient request in the thread (#318): the speaking device is told what it said, once per delivered
/// request, before the acknowledgement and before the request is typed, and the words are never logged.
@Suite(.serialized, .timeLimit(.minutes(1))) struct AmbientHeardTests {
    static let heard = "Rightyo, check our discussion."
    static let clip = AmbientAckClip(pcm: Data(repeating: 1, count: 480), sampleRate: 24_000, text: "On it.")
    static let capable = ["probe", AmbientHeard.capability]

    /// A pipeline over the fixture's one request, recording the heard text and the order of heard, ack and typing.
    private func pipelineOrder(isEcho: Bool = false) async throws -> (order: [String], heard: [String]) {
        let fake = try FakeRightyo(AmbientAcknowledgementTests.fixtureWithNames)
        defer { fake.cleanUp() }
        try fake.install(fixture: "tool-events.jsonl")
        let order = Mutex<[String]>([])
        let heard = Mutex<[String]>([])
        var settings = RightyoAmbientPipeline.Configuration(
            executable: fake.executable, config: fake.config, target: "tmux:demo", binding: "pinned",
            connection: UUID(), allowSynthetic: true, timing: .init(eofGrace: 20, termGrace: 20),
            isEcho: { _ in isEcho }, onAcknowledge: { _ in order.withLock { $0.append("ack") } }
        )
        settings.onHeard = { text in
            heard.withLock { $0.append(text) }
            order.withLock { $0.append("heard") }
        }
        let pipeline = try RightyoAmbientPipeline(
            configuration: settings, dispatcher: OrderDispatcher { order.withLock { $0.append("typed") } }
        )
        pipeline.finishInput()
        _ = try await pipeline.run()
        return (order.withLock { $0 }, heard.withLock { $0 })
    }

    @Test func theHeardTurnIsShownOnceBeforeTheAcknowledgementAndTheTyping() async throws {
        let (order, heard) = try await pipelineOrder()
        #expect(heard == [Self.heard])
        #expect(order == ["heard", "ack", "typed"])
    }

    @Test func anEchoDroppedRequestIsNeverShown() async throws {
        let (order, heard) = try await pipelineOrder(isEcho: true)
        #expect(heard.isEmpty)
        #expect(order.isEmpty)
    }

    /// Through the real listener: a capable phone gets its own words, then the acknowledgement's words and clip, and
    /// no listener event carries the words.
    @Test func aCapablePhoneSeesItsOwnWordsBeforeTheAcknowledgement() async throws {
        let details = try await run(capabilities: Self.capable) { socket in
            let first = try await recipientSocketReceive(on: socket)
            #expect(first.payload == .control(.ambientHeard(targetID: RecipientTestRig.target, text: Self.heard)))
            guard case .text(let words) = try await recipientSocketReceive(on: socket).payload else {
                Issue.record("expected the acknowledgement's words after the heard request")
                return
            }
            #expect(words.text == "On it.")
            _ = try await recipientSocketReceive(on: socket)
        }
        #expect(!details.contains { $0.contains("check our discussion") })
    }

    @Test func aPhoneWithoutTheCapabilityGetsOnlyTheAcknowledgement() async throws {
        _ = try await run(capabilities: ["probe"]) { socket in
            guard case .text(let words) = try await recipientSocketReceive(on: socket).payload else {
                Issue.record("expected the acknowledgement first")
                return
            }
            #expect(words.text == "On it.")
            _ = try await recipientSocketReceive(on: socket)
        }
    }

    /// The send itself: only the named connection, only while it selects the target, and only text the command can
    /// carry. A refusal sends nothing.
    @Test(arguments: ["sent", "other_target", "empty", "oversized", "no_connection", "incapable"])
    func theHeardFrameIsGuarded(_ expected: String) async throws {
        let rig = try await RecipientTestRig.make()
        let listener = try fallbackListener(rig: rig, enabled: false)
        let port = try await listener.start()
        let pair = try await FallbackSocketPair.connect(
            port: port, selecting: [RecipientTestRig.target],
            capabilities: expected == "incapable" ? ["probe"] : Self.capable
        )
        defer { pair.close() }
        let connection = try #require(await listener.heardTestConnectionID())
        var (target, text, named) = (RecipientTestRig.target, Self.heard, connection)
        switch expected {
        case "other_target": target = "tmux:elsewhere"
        case "empty": text = ""
        case "oversized": text = String(repeating: "a", count: PayloadLimits.maxTextBytes + 1)
        case "no_connection": named = UUID()
        default: break
        }
        let sent = await listener.showAmbientHeard(connection: named, target: target, text: text)
        #expect(sent == (expected == "sent"))
        if sent {
            let frame = try await recipientSocketReceive(on: pair.sockets[0])
            #expect(frame.payload == .control(.ambientHeard(targetID: target, text: text)))
        } else {
            try await pair.barrier() // Nothing reached the phone.
        }
        await listener.stop(reason: "synthetic test complete")
    }

    /// One ambient stream from a phone advertising `capabilities`, with the persona's clip; returns every listener
    /// event's detail.
    private func run(
        capabilities: [String], check: (URLSessionWebSocketTask) async throws -> Void
    ) async throws -> [String] {
        let fake = try FakeRightyo(AmbientAcknowledgementTests.fixtureWithNames)
        defer { fake.cleanUp() }
        try fake.install(fixture: "tool-events.jsonl")
        let details = Mutex<[String]>([])
        let acknowledged = Mutex(false)
        let env = try await ambientRig(
            fake, timing: .init(eofGrace: 20, termGrace: 20),
            acknowledgements: AmbientAckLibrary(clips: ["rightyo": [Self.clip]]),
            onEvent: { event in
                details.withLock { $0.append(event.detail ?? "") }
                if event.event == "ambient_acknowledged" { acknowledged.withLock { $0 = true } }
            }
        )
        let pair = try await FallbackSocketPair.connect(
            port: env.port, selecting: [RecipientTestRig.target], capabilities: capabilities
        )
        defer { pair.close() }
        let stream = UUID()
        try await recipientSocketSend(audio(stream, 0), on: pair.sockets[0])
        #expect(await eventually { acknowledged.withLock { $0 } })
        try await check(pair.sockets[0])
        try await recipientSocketSend(audio(stream, 1, final: true), on: pair.sockets[0])
        await env.router.settle()
        await env.listener.stop(reason: "synthetic test complete")
        return details.withLock { $0 }
    }
}

/// Records the moment typing begins.
private struct OrderDispatcher: RightyoAmbientDispatching {
    let typed: @Sendable () -> Void
    func dispatch(_ request: LocalDispatchRequest) async throws -> UUID? {
        typed()
        return UUID()
    }
}

extension WebSocketListener {
    fileprivate func heardTestConnectionID() async -> UUID? {
        guard peers.count == 1, let peer = peers.values.first else { return nil }
        return await peer.session.connectionID
    }
}
#endif
