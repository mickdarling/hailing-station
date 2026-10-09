import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

@Suite struct AmbientAudioSessionTests {
    let sink = RecordingAmbientSink()
    let clock = AmbientTestClock()

    private func openSession(
        _ authorizer: PersonalTerminalAuthorizer, host: HailHost
    ) async throws -> (HostSession, [String]) {
        let session = HostSession(host: host, authorizer: authorizer)
        guard case .hello(let info) = try onlyControl(await session.receive(helloFrame())) else {
            Issue.record("expected hello")
            return (session, [])
        }
        #expect((await session.receive(sessionFrame(payload: .control(.select(targetID: "tmux:a"))))).frames
            .isEmpty)
        return (session, info.capabilities)
    }

    private func ambientHost() async throws -> (HailHost, FakeAdapter) {
        var policy = Policy()
        try policy.allow("tmux:a", binding: "binding-a", tier: .open)
        try policy.allow("tmux:b", binding: "binding-b", tier: .open)
        return try await sessionHost(
            targets: [AdapterTarget(name: "a", binding: "binding-a"), AdapterTarget(name: "b", binding: "binding-b")],
            policy: policy
        )
    }

    private func audioFrame(_ audio: AudioPayload, target: String? = "tmux:a") -> Frame {
        sessionFrame(target: target, payload: .audio(audio))
    }

    @Test func defaultOffAdvertisesNothingNewAndRefusesAudioExactlyAsBefore() async throws {
        let (host, adapter) = try await ambientHost()
        let (session, capabilities) = try await openSession(PersonalTerminalAuthorizer(), host: host)
        #expect(capabilities == ["list_targets", "ping", "select_target", "send_text", "escape", "receive_replies"])
        let result = await session.receive(audioFrame(ambientSegment(stream: UUID(), sequence: 0)))
        #expect(try onlyControl(result) == .error(code: .unauthorized, message: "terminal action is not authorized"))
        #expect(result.disposition == .keepOpen)
        #expect(await adapter.deliveries.isEmpty)
    }

    @Test func enabledAdvertisesStreamAudioAndRoutesSegmentsToTheSinkOnly() async throws {
        let (host, adapter) = try await ambientHost()
        let gate = ambientGate(sink: sink, clock: clock)
        let (session, capabilities) = try await openSession(PersonalTerminalAuthorizer(ambientAudio: gate), host: host)
        #expect(capabilities.last == "stream_audio")
        let stream = UUID()
        #expect((await session.receive(audioFrame(ambientSegment(stream: stream, sequence: 0)))).frames.isEmpty)
        #expect((await session.receive(audioFrame(ambientSegment(stream: stream, sequence: 2, isFinal: true))))
            .frames.isEmpty)
        #expect(sink.segments == [0, 2])
        #expect(sink.endings == [.final])
        #expect(await adapter.deliveries.isEmpty)
    }

    @Test func violationEndsTheStreamButKeepsTheConnection() async throws {
        let (host, adapter) = try await ambientHost()
        let gate = ambientGate(sink: sink, clock: clock)
        let (session, _) = try await openSession(PersonalTerminalAuthorizer(ambientAudio: gate), host: host)
        let stream = UUID()
        _ = await session.receive(audioFrame(ambientSegment(stream: stream, sequence: 0)))
        let bad = await session.receive(audioFrame(ambientSegment(stream: stream, sequence: 1, channels: 2)))
        guard case .error(let code, _) = try onlyControl(bad) else {
            Issue.record("expected refusal")
            return
        }
        #expect(code == .malformed)
        #expect(bad.disposition == .keepOpen)
        #expect(sink.endings == [.malformed])
        // The connection still delivers text after an audio violation.
        #expect((await session.receive(sessionFrame(
            target: "tmux:a", payload: .text(TextPayload(text: "echo hello", isFinal: true))
        ))).frames.isEmpty)
        #expect(await adapter.deliveries.map(\.text) == ["echo hello"])
    }

    @Test func audioForAnotherTargetOrSelectionIsRefused() async throws {
        let (host, _) = try await ambientHost()
        let gate = ambientGate(sink: sink, clock: clock)
        let (session, _) = try await openSession(PersonalTerminalAuthorizer(ambientAudio: gate), host: host)
        let wrongFrame = await session.receive(
            audioFrame(ambientSegment(stream: UUID(), sequence: 0), target: "tmux:b")
        )
        #expect(try onlyControl(wrongFrame) == .error(code: .notAllowed, message: "ambient target is not selected"))
        _ = await session.receive(sessionFrame(payload: .control(.select(targetID: "tmux:b"))))
        let wrongSelection = await session.receive(audioFrame(ambientSegment(stream: UUID(), sequence: 0)))
        #expect(try onlyControl(wrongSelection)
            == .error(code: .notAllowed, message: "ambient target is not selected"))
        #expect(sink.events.isEmpty)
    }

    /// One stream per daemon across sessions; since #366 the newest start holds it (see AmbientTakeOverTests).
    @Test func oneStreamPerDaemonAcrossSessions() async throws {
        let (host, _) = try await ambientHost()
        let authorizer = PersonalTerminalAuthorizer(ambientAudio: ambientGate(sink: sink, clock: clock))
        let (first, _) = try await openSession(authorizer, host: host)
        let (second, _) = try await openSession(authorizer, host: host)
        let stream = UUID()
        #expect((await first.receive(audioFrame(ambientSegment(stream: stream, sequence: 0)))).frames.isEmpty)
        #expect((await second.receive(audioFrame(ambientSegment(stream: UUID(), sequence: 0)))).frames.isEmpty)
        #expect(sink.endings == [.superseded])
        let moved = await first.receive(audioFrame(ambientSegment(stream: stream, sequence: 1)))
        #expect(try onlyControl(moved) == .error(code: .notAllowed, message: "ambient moved to another device"))
        #expect(moved.disposition == .keepOpen)
    }

    @Test func localDispatchNeverAuthorizesAudio() async throws {
        let (host, _) = try await ambientHost()
        let gate = ambientGate(sink: sink, clock: clock)
        let (session, _) = try await openSession(PersonalTerminalAuthorizer(ambientAudio: gate), host: host)
        let refused = await session.authorize(
            audioFrame(ambientSegment(stream: UUID(), sequence: 0)), device: "local"
        ) == nil
        #expect(refused)
        #expect(sink.events.isEmpty)
    }
}
