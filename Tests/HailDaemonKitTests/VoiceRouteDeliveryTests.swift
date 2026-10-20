#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// Routes `scratch`, `deck` and `voice` (not running), plus an allowed non-route `other`, on a fake tmux adapter.
private struct VoiceRouteRig {
    static let scratch = "tmux:scratch", deck = "tmux:deck", other = "tmux:other"
    let host: HailHost
    let adapter: FakeAdapter
    let listener: WebSocketListener
    let clock = RecipientTestClock()

    static func make() async throws -> Self {
        let adapter = FakeAdapter(kind: "tmux", targets: [
            AdapterTarget(name: "scratch", binding: "s"), AdapterTarget(name: "deck", binding: "d"),
            AdapterTarget(name: "other", binding: "o")
        ])
        let registry = Registry()
        try await registry.register(adapter)
        // One authored guard keeps unrelated default-guard wall budgets out of this suite.
        var policy = Policy(guardPatterns: [.init(name: "synthetic guard", regex: "^synthetic guarded command$")],
                            deliveriesPerMinute: 1_000)
        for (target, binding) in [(scratch, "s"), (deck, "d"), (other, "o")] {
            try policy.allow(target, binding: binding, tier: .open)
        }
        let host = try HailHost(registry: registry, store: InMemoryPolicyStore(policy))
        let listener = try WebSocketListener(
            bindAddress: "127.0.0.1", port: 0, host: host, authorizer: PersonalTerminalAuthorizer(),
            hostName: "mac-test", singleTerminalReplyFallback: true, log: { _ in }
        )
        return Self(host: host, adapter: adapter, listener: listener)
    }

    static func routes() throws -> VoiceRoutes {
        try VoiceRoutes(defaultTarget: scratch, routes: [
            .init(target: scratch, name: "Hailing Scratch"), .init(target: deck, name: "Deck"),
            .init(target: "tmux:voice", name: "Voice Work")
        ])
    }

    /// A negotiated session with the owner's routes, selecting `target`, recording into the listener's ledger.
    func session(selecting target: String = scratch, routes: VoiceRoutes? = nil) async throws -> HostSession {
        let session = HostSession(host: host, authorizer: PersonalTerminalAuthorizer().naming(routes),
                                  hostName: "mac-test", now: clock.now, requestClock: clock.instant)
        _ = await session.receive(helloFrame())
        _ = await session.receive(sessionFrame(payload: .control(.select(targetID: target))))
        return session
    }

    static func tap(_ text: String, to target: String = scratch) -> Frame {
        sessionFrame(target: target, payload: .text(TextPayload(text: text)))
    }
}

/// Tap-to-talk voice routing (#636, slice 3): one named request goes to that route and its reply comes back, while
/// the device keeps its selection. Synthetic only: a fake tmux-kind adapter and never-started transports.
@Suite(.serialized, .timeLimit(.minutes(1))) struct VoiceRouteDeliveryTests {
    @Test func aNamedRequestGoesToThatRouteAsHeardAndItsReplyComesBack() async throws {
        let rig = try await VoiceRouteRig.make()
        let (asker, bystander) = (try await rig.session(routes: try VoiceRouteRig.routes()),
                                  try await rig.session(routes: try VoiceRouteRig.routes()))
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
        // The single-selector rule stays exact: neither device selects Deck.
        #expect(!(await peers[0].admitsRequestlessReply(reply)))
        // Selecting away (and back) ends the routed request's claim on the reply, as for any selection.
        _ = await asker.receive(sessionFrame(payload: .control(.select(targetID: VoiceRouteRig.other))))
        _ = await asker.receive(sessionFrame(payload: .control(.select(targetID: VoiceRouteRig.scratch))))
        #expect(!(await peers[0].admitsRequestlessReply(reply, lastInput: route)))
        await rig.listener.stop(reason: "synthetic test complete")
    }

    @Test func anUnnamedRequestGoesToTheSelectedRoute() async throws {
        let rig = try await VoiceRouteRig.make()
        let session = try await rig.session(routes: try VoiceRouteRig.routes())
        for text in ["What's the build status?", "Deck is still stopped", "Hailing Scratch, are you there?"] {
            #expect(await session.receive(VoiceRouteRig.tap(text)).frames.isEmpty)
        }
        #expect(await rig.adapter.deliveries.map(\.target) == ["scratch", "scratch", "scratch"])
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
