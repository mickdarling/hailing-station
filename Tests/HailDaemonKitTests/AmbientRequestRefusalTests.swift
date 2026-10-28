#if os(macOS)
import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit

/// Synthetic loopback playback and logs, not physical-device hearing (#847).
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientRequestRefusalTests {
    @Test(arguments: [true, false], [false, true])
    func ownGuardRefusalIsAudibleAndLoggedWithoutEndingTheRun(withClip: Bool, withRoutes: Bool) async throws {
        let fake = try FakeRightyo("""
        /usr/bin/sed -e '$d' -e "s/tool-demo/$7/g" events.jsonl
        /bin/cat > /dev/null
        /usr/bin/sed -n -e '$p' events.jsonl | /usr/bin/sed "s/tool-demo/$7/g"
        """)
        defer { fake.cleanUp() }
        try Self.fixture().write(to: fake.directory.appendingPathComponent("events.jsonl"), atomically: true,
                                 encoding: .utf8)
        let events = Mutex<[WebSocketListenerEvent]>([])
        let clips = withClip ? [AmbientStopConfirmation.notSent: [AmbientVoiceRouteRefusalTests.notSent]] : [:]
        let env = try await ambientRig(
            fake, timing: .init(eofGrace: 20, termGrace: 20), acknowledgements: AmbientAckLibrary(clips: clips),
            routes: withRoutes ? try AmbientVoiceRouteRefusalTests.routes() : nil,
            guardPatterns: DangerousPatternGuard.defaults + [
                .init(name: "SYNTHETIC_PRIVATE_RULE\ntext=hidden", regex: "SYNTHETIC_GUARDED")
            ],
            onEvent: { event in events.withLock { $0.append(event) } }
        )
        let pair = try await FallbackSocketPair.boundedConnect(port: env.port, selecting: [RecipientTestRig.target])
        defer { pair.close() }
        let stream = UUID()
        try await recipientSocketSend(audio(stream, 0), on: pair.sockets[0])
        #expect(await eventually { events.withLock { $0.contains { $0.event == "ambient_request_refused" } } })
        if withClip { try await checkClip(on: pair.sockets[0]) }
        #expect(await eventually { await env.rig.adapter.contexts.count == 1 })
        let logged = events.withLock { $0 }
        #expect(logged.filter { $0.event == "ambient_request_refused" }.count == 1)
        let refusal = try #require(logged.first { $0.event == "ambient_request_refused" })
        #expect(refusal.detail == "reason=confirmation_required rules=sudo+custom shown=unsupported confirm="
                + (withClip ? "confirmnotsent/0:sent" : "no_clips"))
        #expect(!logged.contains { $0.event == "ambient_ended" })
        #expect(logged.allSatisfy { event in
            let detail = event.detail ?? ""
            return !detail.contains("SYNTHETIC") && !detail.contains(RecipientTestRig.target)
        })
        try await barrier(on: pair.sockets[0], step: "no other output")
        try await recipientSocketSend(audio(stream, 1, final: true), on: pair.sockets[0])
        await boundedSettle(env.router)
        await env.listener.stop(reason: "synthetic test complete")
    }

    @Test func onlyTheGuardedFixtureRequestMatchesARule() throws {
        let requests = try Self.fixture().split(separator: "\n").map { line in
            try RightyoInputEvent.decode(Data(line.utf8))
        }.filter { $0.type == "request" }
        let guards = try CompiledGuards(DangerousPatternGuard.defaults)
        #expect(requests.count == 2)
        let hits = try requests.map {
            guards.matches(in: [try $0.prompt(speakers: "enrolled", target: RecipientTestRig.target)])
        }
        #expect(hits == [["sudo"], []])
    }

    @Test(arguments: [LocalDispatchRefusal.confirmationRequired, .capacityExceeded])
    func aRefusedRequestThenADeliveryStillFinishesAtEOF(_ refusal: LocalDispatchRefusal) async throws {
        let fake = try FakeRightyo(RightyoAmbientPipelineTests.echoFixture)
        defer { fake.cleanUp() }
        try Self.fixture().write(to: fake.directory.appendingPathComponent("events.jsonl"), atomically: true,
                                 encoding: .utf8)
        let refusals = Mutex(0)
        var configuration = RightyoAmbientPipeline.Configuration(
            executable: fake.executable, config: fake.config, target: RecipientTestRig.target,
            binding: "reply-binding", connection: UUID(), allowSynthetic: true,
            timing: .init(eofGrace: 20, termGrace: 2)
        )
        configuration.onDeliveryRefused = { value in
            #expect(value == refusal)
            refusals.withLock { $0 += 1 }
        }
        let dispatcher = FirstRequestRefusingDispatcher(refusal: refusal)
        let pipeline = try RightyoAmbientPipeline(configuration: configuration, dispatcher: dispatcher)
        pipeline.finishInput()
        await bounded("refusal pipeline EOF", within: .seconds(15)) {
            do {
                let summary = try await pipeline.run()
                #expect(summary.delivered == 1)
                #expect(summary.exit == .exited(0))
                #expect(refusals.withLock { $0 } == 1)
                #expect(await dispatcher.attempts == 2)
            } catch { Issue.record(error) }
        }
        await pipeline.stop(grace: 0.1)
    }

    private func checkClip(on socket: URLSessionWebSocketTask) async throws {
        let text = try await receiveFrame(on: socket, step: "not-sent words")
        let audio = try await receiveFrame(on: socket, step: "not-sent clip")
        guard case .text(let words) = text.payload, case .audio(let clip) = audio.payload else {
            Issue.record("expected refusal words and audio")
            return
        }
        #expect(words.text == "Nothing was sent.")
        #expect(clip.bytes == AmbientVoiceRouteRefusalTests.notSent.pcm)
    }

    @Test func needsConfirmationIsReservedAndFallsBackUntilRecorded() {
        let key = AmbientStopConfirmation.needsConfirmation
        let clip = AmbientVoiceRouteRefusalTests.notSent
        let fallback = AmbientAckLibrary(clips: [AmbientStopConfirmation.notSent: [clip]])
        #expect(AmbientStopConfirmation.reserved.contains(key))
        #expect(AmbientStopConfirmation.clip(key, in: fallback)?.persona == AmbientStopConfirmation.notSent)
        let dedicated = AmbientAckLibrary(clips: [key: [clip], AmbientStopConfirmation.notSent: [clip]])
        #expect(dedicated.clips[key] == nil)
        #expect(AmbientStopConfirmation.clip(key, in: dedicated)?.persona == key)
    }

    static func fixture() throws -> String {
        let helper = RightyoInputConsumerTests()
        var events = [try helper.start(speakers: "enrolled")]
        let decision: [String: Any] = ["label": "attend", "recipient_kind": "system", "confidence": 0.9,
                                       "provider": "authored", "model": "fake-v1", "role": "owner"]
        for (index, text) in ["sudo SYNTHETIC_GUARDED", "SYNTHETIC_BENIGN"].enumerated() {
            let id = "r\(index)", sequence = 2 + index * 3, end = 10_000 * (index + 1)
            var turn = helper.roleTurn(id, role: "owner", start: end - 800, end: end)
            turn["text"] = text
            events.append(try helper.event("transcript", sequence: sequence, extra: [
                "turn": turn, "emitted_at_ms": end + 100
            ]))
            events.append(try helper.event("attention", sequence: sequence + 1, extra: [
                "utterance_id": id, "request_id": "tool-demo:\(id)", "decision": decision, "emitted_at_ms": end + 100
            ]))
            events.append(try helper.event("request", sequence: sequence + 2, extra: [
                "request_id": "tool-demo:\(id)", "turn": turn, "decision": decision, "context": ["turns": []],
                "decision_at_ms": end + 100, "emitted_at_ms": end + 100
            ]))
        }
        events.append(try helper.event("session", sequence: 8, extra: ["phase": "stopped", "emitted_at_ms": 30_000]))
        let lines = try events.map { String(bytes: try JSONEncoder().encode($0), encoding: .utf8) ?? "" }
        return lines.joined(separator: "\n") + "\n"
    }
}

private actor FirstRequestRefusingDispatcher: RightyoAmbientDispatching {
    private(set) var attempts = 0
    let refusal: LocalDispatchRefusal

    init(refusal: LocalDispatchRefusal) { self.refusal = refusal }

    func dispatch(_ request: LocalDispatchRequest) async throws -> UUID? {
        attempts += 1
        if attempts == 1 { throw refusal }
        return UUID()
    }
}
#endif
