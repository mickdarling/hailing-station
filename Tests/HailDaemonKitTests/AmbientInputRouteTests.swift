#if os(macOS)
import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

/// rightyo#164: a device names the kind of input its ambient audio comes from, and the host logs it as a token so a
/// speaker-ID mismatch can be attributed to an input chain. Synthetic only.
@Suite(.serialized, .timeLimit(.minutes(1))) struct AmbientInputRouteTests {
    final class RouteSink: AmbientAudioSink {
        let routes = Mutex<[String]>([])
        func ambientAudio(_ event: AmbientAudioEvent) {}
        func ambientInputRoute(_ route: String, connection: UUID) {
            routes.withLock { $0.append("\(connection):\(route)") }
        }
    }

    @Test func onlyAChangePerConnectionIsHandedOnAndADisconnectForgetsIt() async {
        let sink = RouteSink()
        let gate = AmbientAudioGate(target: "tmux:a", sink: sink, sweepInterval: nil)
        let (one, two) = (UUID(), UUID())
        await gate.noteInputRoute("usb_audio", connection: one)
        await gate.noteInputRoute("usb_audio", connection: one) // a repeat: nothing
        await gate.noteInputRoute("usb_audio", connection: two)
        await gate.noteInputRoute("car_audio", connection: one)
        await gate.noteInputRoute("Mick's AirPods", connection: one) // never a name
        await gate.end(connection: one)
        await gate.noteInputRoute("car_audio", connection: one) // forgotten, so noted again
        #expect(sink.routes.withLock { $0 } == [
            "\(one):usb_audio", "\(two):usb_audio", "\(one):car_audio", "\(one):car_audio"
        ])
    }

    /// Through the real listener: the host advertises `ambient_input_route` with ambient listening on, admits the
    /// device's route, answers nothing, and logs `ambient_input route=<kind>` once per change.
    @Test func theListenerAdvertisesAdmitsAndLogsTheRoute() async throws {
        let fake = try FakeRightyo(AmbientAcknowledgementTests.fixtureWithNames)
        defer { fake.cleanUp() }
        try fake.install(fixture: "tool-events.jsonl")
        let logged = Mutex<[String]>([])
        let env = try await ambientRig(fake, timing: .init(eofGrace: 20, termGrace: 20), onEvent: { event in
            if event.event == "ambient_input" { logged.withLock { $0.append(event.detail ?? "") } }
        })
        let (session, socket) = try recipientSocket(port: env.port)
        defer {
            socket.cancel(with: .normalClosure, reason: nil)
            session.invalidateAndCancel()
        }
        try await recipientSocketSend(sessionFrame(payload: .control(.hello(HelloInfo(
            versions: [1], capabilities: ["probe"], deviceName: "test"
        )))), on: socket)
        guard case .control(.hello(let info)) = try await recipientSocketReceive(on: socket).payload else {
            Issue.record("expected the host hello")
            return
        }
        #expect(info.capabilities.contains(AmbientInput.capability))
        for route in ["usb_audio", "usb_audio", "car_audio"] {
            try await recipientSocketSend(sessionFrame(payload: .control(.ambientInput(route: route))), on: socket)
        }
        try await recipientSocketBarrier(on: socket) // nothing answered before the barrier's own reply
        #expect(await eventually { logged.withLock { $0.count == 2 } })
        #expect(logged.withLock { $0 } == ["route=usb_audio", "route=car_audio"])
        await env.listener.stop(reason: "synthetic test complete")
    }

    /// Without ambient listening the host neither advertises nor admits it.
    @Test func withoutAmbientListeningTheRouteIsNeitherAdvertisedNorAdmitted() async {
        let authorizer = PersonalTerminalAuthorizer()
        #expect(!authorizer.capabilities.contains(AmbientInput.capability))
        let frame = Frame(timestamp: 1, source: "terminal", payload: .control(.ambientInput(route: "usb_audio")))
        #expect(await authorizer.authorize(frame) == .deny)
        let gated = PersonalTerminalAuthorizer(
            ambientAudio: AmbientAudioGate(target: "tmux:a", sink: RouteSink(), sweepInterval: nil)
        )
        #expect(gated.capabilities.contains(AmbientInput.capability))
        #expect(await gated.authorize(frame) == .allow)
    }
}
#endif
