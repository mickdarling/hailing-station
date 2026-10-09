import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// #366 through `HostSession`: only negotiated sessions of this daemon, selecting the gate's target, take over; a
/// device that advertised `ambient_takeover` is told where listening came from.
@Suite struct AmbientTakeOverSessionTests {
    let sink = RecordingAmbientSink()
    let clock = AmbientTestClock()

    private func host() async throws -> HailHost {
        var policy = Policy()
        try policy.allow("tmux:a", binding: "binding-a", tier: .open)
        try policy.allow("tmux:b", binding: "binding-b", tier: .open)
        return try await sessionHost(
            targets: [AdapterTarget(name: "a", binding: "binding-a"), AdapterTarget(name: "b", binding: "binding-b")],
            policy: policy
        ).0
    }

    private func session(
        _ authorizer: any HostSessionAuthorizing, host: HailHost, kind: String?, capable: Bool,
        selecting target: String = "tmux:a"
    ) async -> HostSession {
        let session = HostSession(host: host, authorizer: authorizer)
        let capabilities = capable ? [AmbientTakeOver.capability] : []
        _ = await session.receive(sessionFrame(payload: .control(.hello(HelloInfo(
            versions: [1], capabilities: capabilities, deviceName: "test", deviceKind: kind
        )))))
        _ = await session.receive(sessionFrame(payload: .control(.select(targetID: target))))
        return session
    }

    private func audio(_ stream: UUID, _ sequence: Int) -> Frame {
        sessionFrame(target: "tmux:a", payload: .audio(ambientSegment(stream: stream, sequence: sequence)))
    }

    @Test func theNewDeviceIsToldWhereListeningCameFromAndThePreviousWhereItWent() async throws {
        let host = try await host()
        let authorizer = PersonalTerminalAuthorizer(ambientAudio: ambientGate(sink: sink, clock: clock))
        let phone = await session(authorizer, host: host, kind: "phone", capable: true)
        let pad = await session(authorizer, host: host, kind: "pad", capable: true)
        let first = UUID(), second = UUID()
        #expect((await phone.receive(audio(first, 0))).frames.isEmpty)
        let taken = await pad.receive(audio(second, 0))
        #expect(try onlyControl(taken) == .ambientMovedHere(from: "phone"))
        #expect(taken.disposition == .keepOpen)
        #expect(sink.endings == [.superseded])
        let moved = await phone.receive(audio(first, 1))
        #expect(try onlyControl(moved) == .error(code: .notAllowed, message: "ambient moved to pad"))
        #expect(moved.disposition == .keepOpen)
        // "Listen here": the phone's new stream takes it back, the same way.
        #expect(try onlyControl(await phone.receive(audio(UUID(), 0))) == .ambientMovedHere(from: "pad"))
        #expect(try onlyControl(await pad.receive(audio(second, 1)))
            == .error(code: .notAllowed, message: "ambient moved to phone"))
        #expect(sink.endings == [.superseded, .superseded])
    }

    @Test func aDeviceWithoutTheCapabilityTakesOverSilently() async throws {
        let host = try await host()
        let authorizer = PersonalTerminalAuthorizer(ambientAudio: ambientGate(sink: sink, clock: clock))
        let older = await session(authorizer, host: host, kind: nil, capable: false)
        let newer = await session(authorizer, host: host, kind: "pad", capable: false)
        let first = UUID()
        #expect((await older.receive(audio(first, 0))).frames.isEmpty)
        #expect((await newer.receive(audio(UUID(), 0))).frames.isEmpty)
        #expect(sink.endings == [.superseded])
        // An older device still stops on an ordinary ambient refusal.
        #expect(try onlyControl(await older.receive(audio(first, 1)))
            == .error(code: .notAllowed, message: "ambient moved to pad"))
    }

    @Test func noTakeOverWhenTheSecondDeviceHasNotSelectedTheTarget() async throws {
        let host = try await host()
        let authorizer = PersonalTerminalAuthorizer(ambientAudio: ambientGate(sink: sink, clock: clock))
        let phone = await session(authorizer, host: host, kind: "phone", capable: true)
        let pad = await session(authorizer, host: host, kind: "pad", capable: true, selecting: "tmux:b")
        #expect((await phone.receive(audio(UUID(), 0))).frames.isEmpty)
        #expect(try onlyControl(await pad.receive(audio(UUID(), 0)))
            == .error(code: .notAllowed, message: "ambient target is not selected"))
        #expect(sink.endings.isEmpty)
    }

    @Test func noTakeOverFromASessionThisDaemonDidNotAdmitForAmbient() async throws {
        let host = try await host()
        let gate = ambientGate(sink: sink, clock: clock)
        let phone = await session(PersonalTerminalAuthorizer(ambientAudio: gate), host: host, kind: "phone",
                                  capable: true)
        #expect((await phone.receive(audio(UUID(), 0))).frames.isEmpty)
        // A read-only probe, a terminal without ambient enabled, a session that never negotiated, and another
        // daemon's gate (another host) all leave this daemon's stream untouched.
        let probe = await session(ConnectionProbeAuthorizer(), host: host, kind: "pad", capable: true)
        #expect(try onlyControl(await probe.receive(audio(UUID(), 0)))
            == .error(code: .unauthorized, message: "terminal action is not authorized"))
        let plain = await session(PersonalTerminalAuthorizer(), host: host, kind: "pad", capable: true)
        #expect(try onlyControl(await plain.receive(audio(UUID(), 0)))
            == .error(code: .unauthorized, message: "terminal action is not authorized"))
        let unnegotiated = HostSession(host: host, authorizer: PersonalTerminalAuthorizer(ambientAudio: gate))
        let refused = await unnegotiated.receive(audio(UUID(), 0))
        #expect(refused.disposition == .close)
        let otherSink = RecordingAmbientSink()
        let other = await session(PersonalTerminalAuthorizer(ambientAudio: ambientGate(sink: otherSink, clock: clock)),
                                  host: host, kind: "pad", capable: true)
        #expect((await other.receive(audio(UUID(), 0))).frames.isEmpty)
        #expect(sink.endings.isEmpty)
        #expect(sink.events.count == 2)
    }
}
