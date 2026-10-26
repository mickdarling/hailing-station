#if os(macOS)
import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

/// #894: an ambient request refused because the target's input already holds unsent text no longer ends the run
/// (ask 3). The device that said it gets tap-to-talk's fixed refusal line and hears "Nothing was sent.", the log has
/// the refusal's name and outcomes only, and the stream goes on to deliver the next request once the input is clear.
/// Every other refusal still ends the run, as `dispatch deliveryRefused`. Synthetic child and adapter only; not
/// device hearing. Named `AmbientWiring…` so it runs in the serial timing lane.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientWiringInputPendingTests {
    static let line = "the target's input already holds unsent text"
    static let told: [Seen] = [.control(.error(code: .voiceRouteRefused, message: line)), .text("Nothing was sent."),
                               .audio]
    static let logged = "reason=inputPending shown=sent confirm=confirmnotsent/0:sent"

    @Test(arguments: [PendingInputReason.staleInput, .appeared, .tainted])
    func pendingInputIsToldAndTheStreamDeliversTheNextRequest(_ reason: PendingInputReason) async throws {
        let run = try await PendingInputRun.make()
        defer { run.close() }
        await run.env.rig.adapter.failHandoff(with: AdapterError.inputPending(reason: reason))
        try await run.speak()
        #expect(try await Self.seen(on: run.socket) == Self.told)
        #expect(await eventually { !run.log.details("ambient_delivery_refused").isEmpty })
        #expect(run.log.details("ambient_delivery_refused") == [Self.logged])
        #expect(await run.env.gate.activeStream != nil, "the stream goes on")
        // The input was cleared meanwhile: the same child's next request is typed.
        await run.env.rig.adapter.passHandoff()
        try run.release("go2")
        #expect(await eventually { await run.env.rig.adapter.contexts.count == 2 })
        // The synthetic adapter records a handoff before failing it; only the typed one armed a reply recipient.
        let contexts = await run.env.rig.adapter.contexts
        #expect(await eventually { await run.armed(contexts[1].id) })
        #expect(await !run.armed(contexts[0].id))
        // Nothing more reached the device: no `ambient stopped` error, no second line or clip.
        try await barrier(on: run.socket, step: "no ambient error after the refusal")
        #expect(run.log.details("ambient_ended").isEmpty)
        #expect(run.log.details("ambient_delivery_refused").count == 1)
        await run.finish()
        // Tokens only: never the heard words, the line's text or the target.
        #expect(run.log.allDetails.allSatisfy { !$0.contains("discussion") && !$0.contains("Rightyo") })
        #expect(run.log.details("ambient_delivery_refused").allSatisfy {
            !$0.contains("unsent") && !$0.contains(RecipientTestRig.target)
        })
    }

    /// Meeting mode (#735) adds no gate on host clips, as for the acknowledgement and a route refusal's clip: the
    /// refusal is told as in any other mode. Privacy holds every request before dispatch, so it is never refused
    /// (`RightyoInputConsumerTests.whilePrivateARequestIsHeldBackSoPendingInputRefusesNothing`).
    @Test func inMeetingModeTheRefusalIsStillTold() async throws {
        let run = try await PendingInputRun.make(holdFirst: true)
        defer { run.close() }
        await run.env.rig.adapter.failHandoff(with: AdapterError.inputPending(reason: .staleInput))
        try await run.speak()
        #expect(await eventually { await run.env.gate.activeStream != nil })
        let connection = try #require(run.env.connected.all.first)
        run.env.router.setMeeting(on: true, connection: connection, reason: "voice")
        #expect(run.env.router.meetingMode(connection: connection))
        try run.release("go1")
        #expect(try await Self.seen(on: run.socket) == Self.told)
        #expect(await eventually { run.log.details("ambient_delivery_refused") == [Self.logged] })
        #expect(run.log.details("ambient_ended").isEmpty)
        await run.finish()
    }

    @Test func aRebindRefusalStillEndsItAsDeliveryRefused() async throws {
        let fake = try FakeRightyo("/usr/bin/sed \"s/tool-demo/$7/g\" events.jsonl\nexec /bin/sleep 60")
        defer { fake.cleanUp() }
        try fake.install(fixture: "tool-events.jsonl")
        let log = AmbientEventDetails()
        let env = try await ambientRig(fake, timing: .init(eofGrace: 0.1, termGrace: 2), onEvent: { log.record($0) })
        await env.rig.adapter.failHandoff(with: AdapterError.rebound("reply"))
        let pair = try await FallbackSocketPair.boundedConnect(port: env.port, selecting: [RecipientTestRig.target])
        defer { pair.close() }
        try await recipientSocketSend(audio(UUID(), 0), on: pair.sockets[0])
        let told = try await ambientError(on: pair.sockets[0], step: "refused dispatch")
        #expect(await eventually { !log.details("ambient_ended").isEmpty })
        #expect(await env.gate.activeStream == nil, "the stream still ends, as before")
        await env.listener.stop(reason: "synthetic test complete")
        #expect(log.details("ambient_ended") == ["dispatch deliveryRefused"])
        #expect(told == "ambient stopped: dispatch deliveryRefused")
        #expect(log.details("ambient_delivery_refused").isEmpty)
    }
}

extension AmbientWiringInputPendingTests {
    enum Seen: Equatable {
        case control(ControlPayload)
        case text(String)
        case audio
    }

    /// The next three frames on `socket`: the refusal line, then the clip's words and its audio.
    static func seen(on socket: URLSessionWebSocketTask) async throws -> [Seen] {
        var seen: [Seen] = []
        while seen.count < 3 {
            let frame = try await receiveFrame(on: socket, step: "refusal \(seen.count)")
            switch frame.payload {
            case .control(let control): seen.append(.control(control))
            case .text(let text): seen.append(.text(text.text))
            case .audio: seen.append(.audio)
            default: seen.append(.text("unexpected \(frame.payload)"))
            }
        }
        return seen
    }
}

/// Every event the router logged.
final class AmbientEventDetails: Sendable {
    private let events = Mutex<[WebSocketListenerEvent]>([])
    func record(_ event: WebSocketListenerEvent) { events.withLock { $0.append(event) } }
    func details(_ name: String) -> [String] {
        events.withLock { $0.filter { $0.event == name }.map { $0.detail ?? "" } }
    }
    var allDetails: [String] { events.withLock { $0.compactMap(\.detail) } }
}

/// One device, taking request refusals, streaming to a child that sends two requests (see
/// `RightyoAmbientPendingInputTests.twoRequests`), with only the `confirm-not-sent/` clip in the library.
struct PendingInputRun {
    let fake: FakeRightyo
    let env: AmbientWiringRig
    let pair: FallbackSocketPair
    let log: AmbientEventDetails
    var socket: URLSessionWebSocketTask { pair.sockets[0] }

    /// `holdFirst` keeps the first request back until the test releases `go1`.
    static func make(holdFirst: Bool = false) async throws -> Self {
        let fake = try FakeRightyo(RightyoAmbientPendingInputTests.twoRequests)
        try fake.install(fixture: "tool-events.jsonl")
        if !holdFirst { try RightyoAmbientPendingInputTests.release(fake, "go1") }
        let log = AmbientEventDetails()
        let env = try await ambientRig(
            fake, timing: .init(eofGrace: 0.5, termGrace: 2),
            acknowledgements: AmbientAckLibrary(clips: ["confirmnotsent": [AmbientVoiceRouteRefusalTests.notSent]]),
            onEvent: { log.record($0) }
        )
        let pair = try await FallbackSocketPair.boundedConnect(
            port: env.port, selecting: [RecipientTestRig.target], capabilities: ["probe", RequestRefusals.capability]
        )
        return Self(fake: fake, env: env, pair: pair, log: log)
    }

    func speak() async throws { try await recipientSocketSend(audio(UUID(), 0), on: socket) }
    func release(_ name: String) throws { try RightyoAmbientPendingInputTests.release(fake, name) }

    /// Whether a live session holds `id` as a reply request: a recipient armed for it.
    func armed(_ id: UUID) async -> Bool {
        for peer in await env.listener.peers.values where await peer.session.replyRequests[id] != nil { return true }
        return false
    }

    func finish() async { await env.listener.stop(reason: "synthetic test complete") }

    func close() {
        pair.close()
        fake.cleanUp()
    }
}
#endif
