import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

/// The proof a test consumes: `#require` cannot hold a noncopyable value, so this throws instead.
func authorizedInput(_ session: HostSession, _ frame: Frame, device: String) async throws -> AuthorizedInput {
    guard let input = await session.authorize(frame, device: device) else { throw TestSupportError.expectedOneControl }
    return input
}

/// `deliver` accepts only an `AuthorizedInput`, which only the session's single authorizer decision on the
/// exact frame can produce and which delivery consumes: no in-module caller reaches `HailHost.send` past a
/// refusing authorizer, no frame is authorized twice or under a different identity, and no proof is replayed.
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

    private func yieldsNoInput(_ session: HostSession, _ frame: Frame) async -> Bool {
        await session.authorize(frame, device: "phone") == nil
    }

    @Test func selectOnlyAuthorizerYieldsNoInputAndTheFramePathRefuses() async throws {
        let (session, adapter) = try await session(SelectOnlyAuthorizer())
        let selected = await session.receive(sessionFrame(payload: .control(.select(targetID: Self.target))))
        #expect(selected.frames.isEmpty)
        #expect(await session.selectedTarget == Self.target)
        #expect(await yieldsNoInput(session, textFrame()))
        #expect(try onlyControl(await session.receive(textFrame())) == .error(
            code: .unauthorized, message: "terminal action is not authorized"
        ))
        #expect(await adapter.deliveries.isEmpty)
    }

    @Test func connectionProbeSessionYieldsNoInputEvenWithAForcedSelection() async throws {
        let (session, adapter) = try await session(ConnectionProbeAuthorizer())
        await session.forceSelection(Self.target)
        #expect(await yieldsNoInput(session, textFrame()))
        #expect(await adapter.deliveries.isEmpty)
    }

    @Test func unnegotiatedOrWrongVersionFramesYieldNoInput() async throws {
        let (session, _) = try await session(PersonalTerminalAuthorizer(), negotiate: false)
        await session.forceSelection(Self.target)
        #expect(await yieldsNoInput(session, textFrame()))
        _ = await session.receive(helloFrame())
        var wrongVersion = textFrame()
        wrongVersion.version = 2
        #expect(await yieldsNoInput(session, wrongVersion))
    }

    @Test func authorizedInputCarriesTheFramesIdentityAndTheSessionsAttribution() async throws {
        let (session, adapter) = try await session(PersonalTerminalAuthorizer())
        _ = await session.receive(sessionFrame(payload: .control(.select(targetID: Self.target))))
        let frame = textFrame()
        let input = try await authorizedInput(session, frame, device: "local-caller")
        #expect(input.utteranceID == frame.id)
        #expect(input.target == Self.target)
        #expect(input.text == "synthetic input")
        #expect(input.version == 1)
        #expect(input.expectedBinding == nil)
        // Attribution is what the session was told, never the frame's own `source`.
        #expect(frame.source == "terminal")
        #expect(input.device == "local-caller")
        let outcome = await session.deliver(input)
        #expect(outcome == .delivered(request: nil))
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
        let input = try await authorizedInput(session, direct, device: "phone")
        #expect(authorizer.askedTextFrames == [spoken.id, direct.id])
        // The proof is consumed by this call; a second `deliver(input)` does not compile.
        let outcome = await session.deliver(input)
        #expect(outcome == .delivered(request: nil))
        #expect(authorizer.askedTextFrames == [spoken.id, direct.id])
        #expect(await adapter.deliveries.count == 2)
    }

    @Test func phoneFramesAreAttributedToTheHelloNameNotTheFrameSource() async throws {
        // One delivery per minute per device and per target: the second target is still open, so only the
        // device key can refuse the second send. The hello name is "test"; the frames say "terminal".
        var policy = Policy(deliveriesPerMinute: 1)
        try policy.allow(Self.target, binding: "binding", tier: .open)
        try policy.allow("tmux:other", binding: "other", tier: .open)
        let (host, adapter) = try await sessionHost(targets: [
            AdapterTarget(name: "reply", binding: "binding"), AdapterTarget(name: "other", binding: "other")
        ], policy: policy)
        let session = HostSession(host: host, authorizer: PersonalTerminalAuthorizer(), hostName: "mac-test")
        _ = await session.receive(helloFrame())
        #expect(await session.peerName == "test")
        _ = await session.receive(sessionFrame(payload: .control(.select(targetID: Self.target))))
        #expect(await session.receive(textFrame()).frames.isEmpty)
        _ = await session.receive(sessionFrame(payload: .control(.select(targetID: "tmux:other"))))
        var spoofed = sessionFrame(target: "tmux:other", payload: .text(TextPayload(text: "synthetic input")))
        spoofed.source = "someone-else"
        // Attributed to "test" like the first frame, the device budget is spent; a per-frame source would pass.
        #expect(try onlyControl(await session.receive(spoofed)) == .error(
            code: .notAllowed, message: "target action was refused"
        ))
        #expect(await adapter.deliveries.count == 1)
    }
}

extension HostSession {
    /// Test-only: a selection no authorizer granted, to prove the delivery gate is not transitive on `select`.
    func forceSelection(_ target: String) { selectedTarget = target }
}
