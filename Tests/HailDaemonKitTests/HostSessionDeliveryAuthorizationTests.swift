import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

/// `deliver` accepts only an `AuthorizedInput`, which only the session's single authorizer decision on the
/// exact frame can produce: no in-module caller reaches `HailHost.send` past a refusing authorizer, and no
/// frame is authorized twice or under a different identity.
@Suite struct HostSessionDeliveryAuthorizationTests {
    private static let target = "tmux:reply"

    /// Permits negotiation and selection but denies every text frame: Codex's example on #197.
    private struct SelectOnlyAuthorizer: HostSessionAuthorizing {
        let capabilities = ["list_targets", "ping", "select_target"]
        func authorize(_ frame: Frame) async -> HostSessionAuthorization {
            guard case .control(let control) = frame.payload else { return .deny }
            switch control {
            case .hello, .ping, .listTargets, .select: return .allow
            default: return .deny
            }
        }
    }

    /// Records every text frame it is asked about, by id, so a double or substituted query is visible.
    private final class CountingAuthorizer: HostSessionAuthorizing, Sendable {
        let capabilities = PersonalTerminalAuthorizer().capabilities
        private let textFrames = Mutex<[UUID]>([])
        var askedTextFrames: [UUID] { textFrames.withLock { $0 } }
        func authorize(_ frame: Frame) async -> HostSessionAuthorization {
            if case .text = frame.payload { textFrames.withLock { $0.append(frame.id) } }
            return await PersonalTerminalAuthorizer().authorize(frame)
        }
    }

    private func session(
        _ authorizer: any HostSessionAuthorizing, negotiate: Bool = true
    ) async throws -> (HostSession, FakeAdapter) {
        var policy = Policy()
        try policy.allow(Self.target, binding: "binding", tier: .open)
        let (host, adapter) = try await sessionHost(
            targets: [AdapterTarget(name: "reply", binding: "binding")], policy: policy
        )
        let session = HostSession(host: host, authorizer: authorizer, hostName: "mac-test")
        if negotiate { _ = await session.receive(helloFrame()) }
        return (session, adapter)
    }

    private func textFrame() -> Frame {
        sessionFrame(target: Self.target, payload: .text(TextPayload(text: "synthetic input")))
    }

    @Test func selectOnlyAuthorizerYieldsNoInputAndTheFramePathRefuses() async throws {
        let (session, adapter) = try await session(SelectOnlyAuthorizer())
        let selected = await session.receive(sessionFrame(payload: .control(.select(targetID: Self.target))))
        #expect(selected.frames.isEmpty)
        #expect(await session.selectedTarget == Self.target)
        #expect(await session.authorize(textFrame()) == nil)
        #expect(try onlyControl(await session.receive(textFrame())) == .error(
            code: .unauthorized, message: "terminal action is not authorized"
        ))
        #expect(await adapter.deliveries.isEmpty)
    }

    @Test func connectionProbeSessionYieldsNoInputEvenWithAForcedSelection() async throws {
        let (session, adapter) = try await session(ConnectionProbeAuthorizer())
        await session.forceSelection(Self.target)
        #expect(await session.authorize(textFrame()) == nil)
        #expect(await adapter.deliveries.isEmpty)
    }

    @Test func unnegotiatedOrWrongVersionFramesYieldNoInput() async throws {
        let (session, _) = try await session(PersonalTerminalAuthorizer(), negotiate: false)
        await session.forceSelection(Self.target)
        #expect(await session.authorize(textFrame()) == nil)
        _ = await session.receive(helloFrame())
        var wrongVersion = textFrame()
        wrongVersion.version = 2
        #expect(await session.authorize(wrongVersion) == nil)
    }

    @Test func authorizedInputCarriesTheFramesOwnIdentity() async throws {
        let (session, adapter) = try await session(PersonalTerminalAuthorizer())
        _ = await session.receive(sessionFrame(payload: .control(.select(targetID: Self.target))))
        let frame = textFrame()
        let input = try #require(await session.authorize(frame))
        #expect(input.utteranceID == frame.id)
        #expect(input.device == frame.source)
        #expect(input.target == Self.target)
        #expect(input.text == "synthetic input")
        #expect(input.version == 1)
        #expect(input.expectedBinding == nil)
        #expect(await session.deliver(input) == .delivered(request: nil))
        #expect(await adapter.deliveries.count == 1)
    }

    @Test func eachTextFrameIsAuthorizedExactlyOnceUnderItsOwnId() async throws {
        let authorizer = CountingAuthorizer()
        let (session, adapter) = try await session(authorizer)
        _ = await session.receive(sessionFrame(payload: .control(.select(targetID: Self.target))))
        let spoken = textFrame()
        #expect(await session.receive(spoken).frames.isEmpty)
        #expect(authorizer.askedTextFrames == [spoken.id])
        let direct = textFrame()
        let input = try #require(await session.authorize(direct))
        #expect(authorizer.askedTextFrames == [spoken.id, direct.id])
        #expect(await session.deliver(input) == .delivered(request: nil))
        #expect(authorizer.askedTextFrames == [spoken.id, direct.id])
        #expect(await adapter.deliveries.count == 2)
    }
}

extension HostSession {
    /// Test-only: a selection no authorizer granted, to prove the delivery gate is not transitive on `select`.
    func forceSelection(_ target: String) { selectedTarget = target }
}
