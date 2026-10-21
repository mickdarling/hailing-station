#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// Tap-to-talk voice routing (#636, slice 3): one named request goes to that route and its reply comes back, while
/// the device keeps its selection. Synthetic only: a fake tmux-kind adapter and never-started transports.
@Suite(.serialized, .timeLimit(.minutes(1))) struct VoiceRouteDeliveryTests {
    @Test func aNamedRequestGoesToThatRouteAsHeardAndItsReplyComesBack() async throws {
        let rig = try await VoiceRouteRig.make()
        // The bystander selects Deck itself, so only the asker's last-input claim keeps Deck's reply from it.
        let (asker, bystander) = (try await rig.session(routes: try VoiceRouteRig.routes()),
                                  try await rig.session(selecting: VoiceRouteRig.deck,
                                                        routes: try VoiceRouteRig.routes()))
        let peers = await rig.listener.installFallbackSyntheticPeers([asker, bystander])
        #expect(await asker.receive(VoiceRouteRig.tap("Deck, add a slide on pricing")).frames.isEmpty)
        #expect(await rig.adapter.deliveries.map(\.target) == ["deck"])
        #expect(await rig.adapter.deliveries.last?.text == "Deck, add a slide on pricing")
        #expect(await asker.selectedTarget == VoiceRouteRig.scratch, "the selection is unchanged")
        // Deck's request-less reply goes to the device that asked, by its last input, and to nobody else.
        let reply = recipientText(referenceDescriptor(nil, target: VoiceRouteRig.deck))
        let route = try #require(await rig.listener.lastInputRoute(reply))
        #expect(route.entry.connection == (await asker.connectionID))
        #expect(await peers[0].admitsRequestlessReply(reply, lastInput: route))
        #expect(!(await peers[1].admitsRequestlessReply(reply, lastInput: route)))
        // The single-selector rule stays exact: only the device that selects Deck could take it, never the asker.
        #expect(!(await peers[0].admitsRequestlessReply(reply)))
        #expect(await peers[1].admitsRequestlessReply(reply))
        // Selecting away (and back) ends the routed request's claim on the reply, as for any selection.
        _ = await asker.receive(sessionFrame(payload: .control(.select(targetID: VoiceRouteRig.other))))
        _ = await asker.receive(sessionFrame(payload: .control(.select(targetID: VoiceRouteRig.scratch))))
        #expect(!(await peers[0].admitsRequestlessReply(reply, lastInput: route)))
        await rig.listener.stop(reason: "synthetic test complete")
    }

    /// Anything that names no other route goes to the selected one as before, including its own name alone.
    @Test func anUnnamedRequestGoesToTheSelectedRoute() async throws {
        let rig = try await VoiceRouteRig.make()
        let session = try await rig.session(routes: try VoiceRouteRig.routes())
        let texts = ["What's the build status?", "Deck is still stopped", "Hailing Scratch, are you there?",
                     "Hailing Scratch"]
        for text in texts {
            #expect(await session.receive(VoiceRouteRig.tap(text)).frames.isEmpty)
        }
        #expect(await rig.adapter.deliveries.map(\.target) == Array(repeating: "scratch", count: texts.count))
    }

    /// The asker's claim on Deck's reply lasts the last-input lifetime (#370); after it, a device selecting Deck takes it.
    @Test func theAskersClaimEndsWithTheLastInputLifetime() async throws {
        let rig = try await VoiceRouteRig.make()
        let (asker, deckSelector) = (try await rig.session(routes: try VoiceRouteRig.routes()),
                                     try await rig.session(selecting: VoiceRouteRig.deck))
        let peers = await rig.listener.installFallbackSyntheticPeers([asker, deckSelector])
        #expect(await asker.receive(VoiceRouteRig.tap("Deck, add a slide")).frames.isEmpty)
        let reply = recipientText(referenceDescriptor(nil, target: VoiceRouteRig.deck))
        let route = try #require(await rig.listener.lastInputRoute(reply))
        rig.clock.advance(Int64(LastInputLedger.lifetime.components.seconds) * 1_000 + 1)
        #expect(!(await peers[0].admitsRequestlessReply(reply, lastInput: route)))
        #expect(await peers[1].admitsRequestlessReply(reply))
        await rig.listener.stop(reason: "synthetic test complete")
    }

    /// A route running but never allowed is offline, and a policy that cannot be read says so; nothing is sent.
    @Test func aRouteWithoutPolicyIsOfflineAndAnUnreadablePolicySaysSo() async throws {
        let rig = try await VoiceRouteRig.make()
        let session = try await rig.session(routes: try VoiceRouteRig.routes())
        let rogue = await session.receive(VoiceRouteRig.tap("Rogue, run it"))
        #expect(try onlyControl(rogue) == .error(code: .unknownTarget,
                                                 message: "voice route: Rogue is offline; nothing was sent"))
        rig.store.setLoadError(PolicyFileError.malformed("policy.json: synthetic"))
        let unreadable = await session.receive(VoiceRouteRig.tap("Deck, add a slide"))
        #expect(try onlyControl(unreadable) == .error(
            code: .malformed, message: "voice route: the target list is unavailable; nothing was sent"
        ))
        #expect(await rig.adapter.deliveries.isEmpty)
    }

    /// No silent fallback: an offline route, a name alone or a misheard name sends nothing anywhere and says so.
    @Test(arguments: [
        ("Voice Work, run the tests", ErrorCode.unknownTarget, "voice route: Voice Work is offline; nothing was sent"),
        ("Deck", .malformed, "voice route: nothing to send to Deck"),
        ("Hailing Scratcher, hello", .notAllowed, "voice route: which session? Nothing was sent")
    ])
    func anAddressThatCannotBeDeliveredSendsNothing(_ text: String, _ code: ErrorCode, _ message: String) async throws {
        let rig = try await VoiceRouteRig.make()
        let session = try await rig.session(routes: try VoiceRouteRig.routes())
        let result = await session.receive(VoiceRouteRig.tap(text))
        #expect(try onlyControl(result) == .error(code: code, message: message))
        #expect(result.disposition == .keepOpen)
        #expect(await rig.adapter.deliveries.isEmpty)
    }

    /// During lockdown nothing is routed: a named request meets the lockdown refusal as it is, never "offline".
    @Test func lockdownRefusesANamedRequestAsLockdown() async throws {
        let rig = try await VoiceRouteRig.make()
        let session = try await rig.session(routes: try VoiceRouteRig.routes())
        _ = await rig.host.engageLockdown(reason: "synthetic")
        for text in ["Deck, add a slide", "Voice Work, run the tests"] {
            let result = await session.receive(VoiceRouteRig.tap(text))
            guard case .error(let code, _) = try onlyControl(result) else { throw TestSupportError.expectedOneControl }
            #expect(code == .lockdown)
        }
        #expect(await rig.adapter.deliveries.isEmpty)
    }

    /// A name with nothing spoken after it routes when a paste goes with it (#608), and the paste gate judges the
    /// routed target, not the selected one: a paste routed to the agent is delivered, one routed to a tmux pane refused.
    @Test func aNameAloneWithAPasteRoutesAndTheRoutedTargetsPasteGateDecides() async throws {
        let rig = try await VoiceRouteRig.make()
        let onScratch = try await rig.session(routes: try VoiceRouteRig.routes())
        let toAgent = sessionFrame(target: VoiceRouteRig.scratch, payload: .text(TextPayload(
            text: "Agent:", pasted: PastedText(text: "synthetic pasted notes")
        )))
        #expect(await onScratch.receive(toAgent).frames.isEmpty)
        #expect(await rig.agentAdapter.deliveries.map(\.target) == ["agent"])
        #expect(await rig.agentAdapter.deliveries.last?.text.contains("synthetic pasted notes") == true)
        let onAgent = try await rig.session(selecting: VoiceRouteRig.agent, routes: try VoiceRouteRig.routes())
        let toDeck = sessionFrame(target: VoiceRouteRig.agent, payload: .text(TextPayload(
            text: "Deck:", pasted: PastedText(text: "synthetic pasted notes")
        )))
        let refused = await onAgent.receive(toDeck)
        #expect(try onlyControl(refused) == .error(code: .malformed, message: PastedContent.agentOnlyRefusal))
        #expect(await rig.adapter.deliveries.isEmpty)
    }

    /// Only a frame the host routed itself may name another route; a device cannot address one directly.
    @Test func aFrameAddressedToAnotherRouteByTheDeviceIsRefused() async throws {
        let rig = try await VoiceRouteRig.make()
        let session = try await rig.session(routes: try VoiceRouteRig.routes())
        let result = await session.receive(VoiceRouteRig.tap("add a slide", to: VoiceRouteRig.deck))
        #expect(try onlyControl(result) == .error(code: .notAllowed, message: "select the destination before speaking"))
        #expect(await rig.adapter.deliveries.isEmpty)
    }

    @Test func routingNeedsTheRoutesFileAndASelectedRoute() async throws {
        let rig = try await VoiceRouteRig.make()
        let unrouted = try await rig.session()
        #expect(await unrouted.receive(VoiceRouteRig.tap("Deck, add a slide")).frames.isEmpty)
        let onOther = try await rig.session(selecting: VoiceRouteRig.other, routes: try VoiceRouteRig.routes())
        let other = VoiceRouteRig.tap("Deck, add a slide", to: VoiceRouteRig.other)
        #expect(await onOther.receive(other).frames.isEmpty)
        #expect(await rig.adapter.deliveries.map(\.target) == ["scratch", "other"])
    }
}
#endif
