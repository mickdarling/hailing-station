#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// What a device that advertised `request_refusals` (#665) is told for each refusal near a voice route (#636, second-key
/// reviews on #701): the routing step's own refusals are `voice_route_refused`; lockdown and the routed target's paste
/// gate keep their own codes. Nothing is sent anywhere. Synthetic only.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct VoiceRouteRefusalCodeTests {
    static func capable(_ rig: VoiceRouteRig, selecting target: String = VoiceRouteRig.scratch) async throws
        -> HostSession {
        let authorizer = PersonalTerminalAuthorizer().naming(try VoiceRouteRig.routes())
        let session = HostSession(host: rig.host, authorizer: authorizer, hostName: "mac-test")
        _ = await session.receive(helloFrame(capabilities: [RequestRefusals.capability]))
        _ = await session.receive(sessionFrame(payload: .control(.select(targetID: target))))
        return session
    }

    @Test func anUnreadableTargetListIsAVoiceRouteRefusal() async throws {
        let rig = try await VoiceRouteRig.make()
        let session = try await Self.capable(rig)
        rig.store.setLoadError(PolicyFileError.malformed("policy.json: synthetic"))
        let result = await session.receive(VoiceRouteRig.tap("Deck, add a slide"))
        #expect(try onlyControl(result) == .error(
            code: .voiceRouteRefused, message: "voice route: the target list is unavailable; nothing was sent"
        ))
        #expect(result.disposition == .keepOpen)
        #expect(await rig.adapter.deliveries.isEmpty)
    }

    @Test func lockdownStillAnswersAsLockdown() async throws {
        let rig = try await VoiceRouteRig.make()
        let session = try await Self.capable(rig)
        _ = await rig.host.engageLockdown(reason: "synthetic")
        let pasted = sessionFrame(target: VoiceRouteRig.scratch, payload: .text(TextPayload(
            text: "Deck:", pasted: PastedText(text: "synthetic pasted notes")
        )))
        for frame in [VoiceRouteRig.tap("Deck, add a slide"), VoiceRouteRig.tap("Voice Work, run the tests"), pasted] {
            guard case .error(let code, _) = try onlyControl(await session.receive(frame)) else {
                throw TestSupportError.expectedOneControl
            }
            #expect(code == .lockdown)
        }
        #expect(await rig.adapter.deliveries.isEmpty)
    }

    /// A paste routed to a tmux pane passes the routing step and meets that target's paste gate: `paste_refused`.
    @Test func theRoutedTargetsPasteGateKeepsItsOwnCode() async throws {
        let rig = try await VoiceRouteRig.make()
        let session = try await Self.capable(rig, selecting: VoiceRouteRig.agent)
        let toDeck = sessionFrame(target: VoiceRouteRig.agent, payload: .text(TextPayload(
            text: "Deck:", pasted: PastedText(text: "synthetic pasted notes")
        )))
        let result = await session.receive(toDeck)
        #expect(try onlyControl(result) == .error(code: .pasteRefused, message: PastedContent.agentOnlyRefusal))
        #expect(result.disposition == .keepOpen)
        #expect(await rig.adapter.deliveries.isEmpty)
        #expect(await rig.agentAdapter.deliveries.isEmpty)
    }
}
#endif
