import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// #398: a host with ambient listening advertises `ambient_overheard` and keeps each connection's `overheard_scope`,
/// starting at `off`; a host without it refuses the command and changes nothing.
@Suite struct OverheardScopeSessionTests {
    private func open(ambient: Bool) async throws -> (HostSession, [String]) {
        let (host, _) = try await sessionHost(targets: [AdapterTarget(name: "a", binding: "binding-a")])
        let gate = ambient ? AmbientAudioGate(target: "tmux:a", sink: RecordingAmbientSink(), sweepInterval: nil) : nil
        let session = HostSession(host: host, authorizer: PersonalTerminalAuthorizer(ambientAudio: gate))
        guard case .hello(let info) = try onlyControl(await session.receive(helloFrame())) else {
            Issue.record("expected hello")
            return (session, [])
        }
        return (session, info.capabilities)
    }

    @Test func anAmbientHostAdvertisesItAndEachConnectionStartsOff() async throws {
        let (session, capabilities) = try await open(ambient: true)
        #expect(capabilities.contains(AmbientOverheard.capability))
        #expect(await session.overheardScope == "off")
        for scope in ["owner", "everyone", "off"] {
            let result = await session.receive(sessionFrame(payload: .control(.overheardScope(scope: scope))))
            #expect(result.frames.isEmpty && result.disposition == .keepOpen)
            #expect(await session.overheardScope == scope)
        }
        let (fresh, _) = try await open(ambient: true)
        #expect(await fresh.overheardScope == "off", "a new connection never inherits a scope")
    }

    @Test func withoutAmbientItIsNeitherAdvertisedNorAccepted() async throws {
        let (session, capabilities) = try await open(ambient: false)
        #expect(!capabilities.contains(AmbientOverheard.capability))
        let result = await session.receive(sessionFrame(payload: .control(.overheardScope(scope: "everyone"))))
        #expect(try onlyControl(result) == .error(code: .unauthorized, message: "terminal action is not authorized"))
        #expect(result.disposition == .keepOpen)
        #expect(await session.overheardScope == "off")
    }

    @Test func aDeviceCannotSendOverheardTurnsToTheHost() async throws {
        let (session, _) = try await open(ambient: true)
        let result = await session.receive(sessionFrame(
            payload: .control(.ambientOverheard(targetID: "tmux:a", text: "hi", speaker: "owner"))
        ))
        #expect(try onlyControl(result) == .error(code: .unauthorized, message: "terminal action is not authorized"))
    }
}
