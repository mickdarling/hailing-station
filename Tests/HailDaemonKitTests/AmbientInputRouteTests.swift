#if os(macOS)
import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

/// rightyo#164: a device names the kind of input its ambient audio comes from, and the host logs it as a token so a
/// speaker-ID mismatch can be attributed to an input chain. Synthetic only.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientWiringInputRouteTests {
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

    /// A stream boundary resets it: the route a device resends at its next stream's start is noted again.
    @Test func theRouteIsNotedAgainAfterItsStreamEnds() async {
        let sink = RouteSink()
        let gate = AmbientAudioGate(target: "tmux:a", sink: sink, sweepInterval: nil)
        let connection = UUID()
        await gate.noteInputRoute("usb_audio", connection: connection)
        let stream = UUID()
        #expect(await gate.admit(ambientSegment(stream: stream, sequence: 0), connection: connection) == nil)
        await gate.noteInputRoute("usb_audio", connection: connection) // the same stream: nothing
        #expect(await gate.admit(ambientSegment(stream: stream, sequence: 1, isFinal: true), connection: connection)
            == nil)
        await gate.noteInputRoute("usb_audio", connection: connection) // the next stream's start: noted again
        #expect(sink.routes.withLock { $0 } == ["\(connection):usb_audio", "\(connection):usb_audio"])
    }

    /// A route line is telemetry: it never becomes the last ambient event `haild doctor` reads health from.
    @Test func aRouteLineNeverHidesAFailedRun() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("hail-route-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("status.json")
        let recorder = DaemonStatusRecorder(file: file, hostID: "themachine.local", build: nil, ambientEnabled: true,
                                            pid: 4242, now: { Date(timeIntervalSince1970: 2_000) })
        recorder.observe(.init(event: "ambient_started"))
        recorder.observe(.init(event: "ambient_ended", detail: "child transportLost"))
        recorder.observe(.init(event: "ambient_input", sessionID: UUID(), detail: "route=usb_audio"))
        let status = try #require(DaemonStatus.read(from: file))
        let ambient = try #require(status.ambient)
        #expect(ambient.lastEvent == "ambient_ended" && ambient.lastDetail == "child transportLost")
    }

    /// The route line is only enqueued: the gate's call returns while the log is still blocked.
    @Test func theGateNeverWaitsForTheRouteLine() async throws {
        let fake = try FakeRightyo(AmbientWiringAcknowledgementTests.fixtureWithNames)
        defer { fake.cleanUp() }
        let release = DispatchSemaphore(value: 0), logged = Mutex(false)
        let env = try await ambientRig(fake, timing: .init(eofGrace: 20, termGrace: 20), onEvent: { event in
            guard event.event == "ambient_input" else { return }
            release.wait()
            logged.withLock { $0 = true }
        })
        let began = ContinuousClock.now
        env.router.ambientInputRoute("usb_audio", connection: UUID())
        #expect(ContinuousClock.now - began < .milliseconds(500))
        #expect(!logged.withLock { $0 })
        release.signal()
        #expect(await eventually { logged.withLock { $0 } })
        await env.listener.stop(reason: "synthetic test complete")
    }

    /// Through the real listener: the host advertises `ambient_input_route` with ambient listening on, admits the
    /// device's route, answers nothing, and logs `ambient_input route=<kind>` once per change.
    @Test func theListenerAdvertisesAdmitsAndLogsTheRoute() async throws {
        let fake = try FakeRightyo(AmbientWiringAcknowledgementTests.fixtureWithNames)
        defer { fake.cleanUp() }
        try fake.install(fixture: "tool-events.jsonl")
        let logged = Mutex<[String]>([]), connections = Mutex<Set<UUID?>>([])
        let env = try await ambientRig(fake, timing: .init(eofGrace: 20, termGrace: 20), onEvent: { event in
            guard event.event == "ambient_input" else { return }
            logged.withLock { $0.append(event.detail ?? "") }
            connections.withLock { _ = $0.insert(event.sessionID) }
        })
        let (session, socket) = try recipientSocket(port: env.port)
        defer {
            socket.cancel(with: .normalClosure, reason: nil)
            session.invalidateAndCancel()
        }
        try await recipientSocketSend(sessionFrame(payload: .control(.hello(HelloInfo(
            versions: [1], capabilities: ["probe"], deviceName: "test"
        )))), on: socket)
        guard case .control(.hello(let info)) = try await receiveFrame(on: socket, step: "host hello").payload else {
            Issue.record("expected the host hello")
            return
        }
        #expect(info.capabilities.contains(AmbientInput.capability))
        for route in ["usb_audio", "usb_audio", "car_audio"] {
            try await recipientSocketSend(sessionFrame(payload: .control(.ambientInput(route: route))), on: socket)
        }
        try await barrier(on: socket, step: "input routes sent") // nothing answered before the barrier's own reply
        #expect(await eventually { logged.withLock { $0.count == 2 } })
        #expect(logged.withLock { $0 } == ["route=usb_audio", "route=car_audio"])
        // Each line names its connection, the same id its stream's `ambient_started` line carries.
        #expect(connections.withLock { $0.count == 1 && !$0.contains(nil) })
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
