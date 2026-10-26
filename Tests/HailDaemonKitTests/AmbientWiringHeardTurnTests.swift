#if os(macOS)
import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientWiringHeardTurnTests {
    @Test func pendingInputEchoesItsHeardTurnAndSuccessfulDeliveryClearsTheNextOne() async throws {
        let run = try await PendingInputRun.make(options: .init(capabilities: HeardTurnRig.capabilities))
        defer { run.close() }
        await run.adapter.failHandoff(with: AdapterError.inputPending(reason: .staleInput))
        try await run.speak()
        let turn1 = try await heard(on: run.socket)
        #expect(try await run.seen(2) == AmbientWiringInputPendingTests.acknowledged)
        let refusal = try await receiveFrame(on: run.socket, step: "correlated input-pending refusal")
        #expect(refusal.payload == .control(.error(code: .voiceRouteRefused,
                                                  message: AmbientWiringInputPendingTests.line, turn: turn1)))
        #expect(try await run.seen(2) == [.text("Nothing was sent."), .audio])
        #expect(await eventually { !run.log.details("ambient_delivery_refused").isEmpty })
        let connection = try #require(await run.connection)
        #expect(await run.env.listener.heardTurnCount(connection) == 0)
        await run.adapter.passHandoff()
        try run.release("go2")
        let turn2 = try await heard(on: run.socket)
        #expect(turn1 != turn2)
        #expect(try await run.seen(2) == AmbientWiringInputPendingTests.acknowledged)
        #expect(await eventually { await run.adapter.contexts.count == 2 })
        #expect(await eventually { await run.env.listener.heardTurnCount(connection) == 0 })
        try await barrier(on: run.socket, step: "successful request has no refusal")
        await run.finish()
        #expect(run.log.allDetails.allSatisfy {
            !$0.contains("discussion") && !$0.contains("Rightyo")
                && !$0.contains(turn1.uuidString) && !$0.contains(turn2.uuidString)
        })
    }

    @Test func aDelayedRefusalKeepsItsTurnWhileTheNextRequestCompletes() async throws {
        let latch = MeetingLatch()
        defer { latch.open() }
        let run = try await PendingInputRun.make(options: .init(capabilities: HeardTurnRig.capabilities),
                                                 hold: AcknowledgementHold { await latch.wait() })
        defer { run.close() }
        await run.adapter.failHandoff(with: AdapterError.inputPending(reason: .staleInput))
        try await run.speak()
        let turn1 = try await heard(on: run.socket)
        #expect(await eventually { await run.adapter.contexts.count == 1 })
        await run.adapter.passHandoff()
        try run.release("go2")
        let turn2 = try await heard(on: run.socket)
        #expect(turn1 != turn2)
        let connection = try #require(await run.connection)
        #expect(await eventually { await run.adapter.contexts.count == 2 })
        #expect(await eventually { await run.env.listener.heardTurnCount(connection) == 1 })
        try await barrier(on: run.socket, step: "both acknowledgements and the first refusal are held")
        latch.open()
        let controls = try await run.seen(7).compactMap { frame -> ControlPayload? in
            if case .control(let control) = frame { return control }
            return nil
        }
        #expect(controls == [.error(code: .voiceRouteRefused,
                                    message: AmbientWiringInputPendingTests.line, turn: turn1)])
        #expect(await eventually { await run.env.listener.heardTurnCount(connection) == 0 })
        await run.finish()
        #expect(run.log.allDetails.allSatisfy {
            !$0.contains("discussion") && !$0.contains(turn1.uuidString) && !$0.contains(turn2.uuidString)
        })
    }

    @Test func dispatchFailureStillCompletesTheHeardRequest() async throws {
        let fake = try FakeRightyo(AmbientWiringAcknowledgementTests.fixtureWithNames)
        defer { fake.cleanUp() }
        try fake.install(fixture: "tool-events.jsonl")
        let shown = Mutex<[UUID]>([])
        let finished = Mutex<[UUID]>([])
        var settings = RightyoAmbientPipeline.Configuration(
            executable: fake.executable, config: fake.config, target: "tmux:demo", binding: "pinned",
            connection: UUID(), allowSynthetic: true, timing: .init(eofGrace: 0.5, termGrace: 2)
        )
        settings.heardRequests = AmbientHeardRequests(show: { request, _ in
            shown.withLock { $0.append(request) }
        }, finish: { request, refusal in
            #expect(refusal == nil)
            finished.withLock { $0.append(request) }
        })
        let pipeline = try RightyoAmbientPipeline(configuration: settings, dispatcher: HeardTurnFailingDispatcher())
        pipeline.finishInput()
        await #expect(throws: (any Error).self) { _ = try await pipeline.run() }
        #expect(shown.withLock { $0.count } == 1)
        #expect(shown.withLock { $0 } == finished.withLock { $0 })
    }

    @Test func aRequestWithoutHeardTextStillGetsItsUncorrelatedRefusalCallback() async {
        let shown = Mutex(0)
        let finished = Mutex(0)
        let relay = AmbientHeardRelay(onHeard: nil, requests: AmbientHeardRequests(show: { _, _ in
            shown.withLock { $0 += 1 }
        }, finish: { _, refusal in
            #expect(refusal == .inputPending)
            finished.withLock { $0 += 1 }
        }))
        await relay.deliver()
        await relay.finish(refusal: .inputPending)
        await relay.finish()
        #expect(shown.withLock { $0 } == 0)
        #expect(finished.withLock { $0 } == 1)
    }

    private func heard(on socket: URLSessionWebSocketTask) async throws -> UUID {
        let frame = try await receiveFrame(on: socket, step: "pipeline heard turn")
        guard case .control(.ambientHeard(_, let text, let turn)) = frame.payload else {
            throw TestSupportError.expectedOneControl
        }
        #expect(text.contains("discussion"))
        return try #require(turn)
    }
}

private struct HeardTurnFailingDispatcher: RightyoAmbientDispatching {
    func dispatch(_ request: LocalDispatchRequest) async throws -> UUID? { throw LocalDispatchRefusal.bindingMismatch }
}
#endif
