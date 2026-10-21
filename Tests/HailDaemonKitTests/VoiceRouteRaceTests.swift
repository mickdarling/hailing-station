#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// Suspends one authorize call, so a test can move the selection inside the voice-route step itself (#636; second-key
/// probes from #688, committed here as agreed).
private actor RouteGate {
    var armedCall: Int?
    var calls = 0
    var waiting: CheckedContinuation<Void, Never>?
    var reached: CheckedContinuation<Void, Never>?
    var hasReached = false
    func arm(call: Int) {
        armedCall = call
        calls = 0
    }
    func enter() async {
        calls += 1
        guard calls == armedCall else { return }
        hasReached = true
        reached?.resume()
        reached = nil
        await withCheckedContinuation { waiting = $0 }
    }
    func waitReached() async {
        if hasReached { return }
        await withCheckedContinuation { reached = $0 }
    }
    func release() {
        waiting?.resume()
        waiting = nil
    }
}

private struct GatedRouteAuthorizer: HostSessionAuthorizing {
    let base: PersonalTerminalAuthorizer
    let gate: RouteGate
    var capabilities: [String] { base.capabilities }
    var voiceRoutes: VoiceRoutes? { base.voiceRoutes }
    var health: (@Sendable () async -> HostHealth)? { base.health }
    func authorize(_ frame: Frame) async -> HostSessionAuthorization {
        if case .text = frame.payload { await gate.enter() }
        return await base.authorize(frame)
    }
}

@Suite(.serialized, .timeLimit(.minutes(1))) struct VoiceRouteRaceTests {
    fileprivate func gated(_ rig: VoiceRouteRig, call: Int) async throws -> (HostSession, RouteGate) {
        let gate = RouteGate()
        await gate.arm(call: call)
        let base = PersonalTerminalAuthorizer().naming(try VoiceRouteRig.routes())
        let auth = GatedRouteAuthorizer(base: base, gate: gate)
        let session = HostSession(host: rig.host, authorizer: auth, hostName: "mac-test",
                                  now: rig.clock.now, requestClock: rig.clock.instant)
        _ = await session.receive(helloFrame())
        _ = await session.receive(sessionFrame(payload: .control(.select(targetID: VoiceRouteRig.scratch))))
        return (session, gate)
    }

    /// Call 1 is the voice-route step's own authorize, call 2 is `admit`'s: the selection moves at either and the
    /// routed frame is refused, delivered nowhere, so the generation captured on entry is what holds (4e47a7a).
    @Test(arguments: [(1, 0), (1, 1), (1, 2), (2, 0), (2, 1), (2, 2)])
    func selectionMovesWhileRouting(_ call: Int, _ mode: Int) async throws {
        let rig = try await VoiceRouteRig.make()
        let (session, gate) = try await gated(rig, call: call)
        let sending = Task { await session.receive(VoiceRouteRig.tap("Deck, add a slide")) }
        await gate.waitReached()
        switch mode {
        case 0: // away to the route target itself
            _ = await session.receive(sessionFrame(payload: .control(.select(targetID: VoiceRouteRig.deck))))
        case 1: // away and back
            _ = await session.receive(sessionFrame(payload: .control(.select(targetID: VoiceRouteRig.other))))
            _ = await session.receive(sessionFrame(payload: .control(.select(targetID: VoiceRouteRig.scratch))))
        default: // away to a non-route
            _ = await session.receive(sessionFrame(payload: .control(.select(targetID: VoiceRouteRig.other))))
        }
        await gate.release()
        let result = await sending.value
        guard case .error(let code, _) = try onlyControl(result) else { throw TestSupportError.expectedOneControl }
        #expect(code == .notAllowed)
        #expect(await rig.adapter.deliveries.isEmpty, "nothing delivered anywhere")
    }

    /// Health and listing with routes configured and a route selected: answered as on main, routing never applies.
    @Test func healthIsAnsweredWithRoutesSelected() async throws {
        let rig = try await VoiceRouteRig.make()
        let report = HostHealth(version: "0.1.0", build: "0123456789abcdef", checks: [
            .init(name: "daemon_running", ok: true)
        ])
        let auth = PersonalTerminalAuthorizer(health: { report }).naming(try VoiceRouteRig.routes())
        let session = HostSession(host: rig.host, authorizer: auth, hostName: "mac-test",
                                  now: rig.clock.now, requestClock: rig.clock.instant)
        _ = await session.receive(helloFrame())
        _ = await session.receive(sessionFrame(payload: .control(.select(targetID: VoiceRouteRig.scratch))))
        _ = await rig.host.engageLockdown(reason: "synthetic")
        let result = await session.receive(sessionFrame(target: VoiceRouteRig.scratch, payload: .control(.health)))
        #expect(try onlyControl(result) == .healthReport(report))
        #expect(await rig.adapter.deliveries.isEmpty)
    }

    /// A reply naming the route with a reply descriptor is never routed (text.reply != nil).
    @Test func aFrameCarryingAReplyIsNeverRouted() async throws {
        let rig = try await VoiceRouteRig.make()
        let session = try await rig.session(routes: try VoiceRouteRig.routes())
        let reply = recipientText(referenceDescriptor(nil, target: VoiceRouteRig.scratch))
        var routedAttempt = reply
        if case .text(var payload) = reply.payload {
            payload.text = "Deck, add a slide"
            routedAttempt.payload = .text(payload)
        }
        _ = await session.receive(routedAttempt)
        #expect(await rig.adapter.deliveries.allSatisfy { $0.target != "deck" })
    }

    /// Reconnect: a fresh connection on the same route never inherits the old one's routed claim.
    @Test func aReconnectedDeviceDoesNotInheritTheRoutedClaim() async throws {
        let rig = try await VoiceRouteRig.make()
        let asker = try await rig.session(routes: try VoiceRouteRig.routes())
        await rig.listener.installFallbackSyntheticPeers([asker])
        #expect(await asker.receive(VoiceRouteRig.tap("Deck, add a slide")).frames.isEmpty)
        let reply = recipientText(referenceDescriptor(nil, target: VoiceRouteRig.deck))
        let route = try #require(await rig.listener.lastInputRoute(reply))
        let fresh = try await rig.session(routes: try VoiceRouteRig.routes())
        let peers = await rig.listener.installFallbackSyntheticPeers([fresh])
        #expect(!(await peers[0].admitsRequestlessReply(reply, lastInput: route)))
        #expect(!(await peers[0].admitsRequestlessReply(reply)))
        await rig.listener.stop(reason: "synthetic test complete")
    }
}
@Suite(.serialized, .timeLimit(.minutes(1))) struct VoiceRouteRecordRaceTests {
    /// The FIRST reply frame naming the routed record but claiming the selected route must be refused
    /// (VoiceRouteRecordTests' wrongTarget check runs after a text frame was already accepted).
    @Test func aFirstFrameClaimingTheSelectedRouteForARoutedRecordIsRefused() async throws {
        let rig = try await RecipientTestRig.make()
        let asker = try await VoiceRouteRecordTests.session(rig)
        #expect(await asker.receive(VoiceRouteRecordTests.tap("Other, check the build")).frames.isEmpty)
        let context = try #require(await rig.adapter.contexts.last)
        let wrongTarget = recipientText(ReplyDescriptor(id: UUID(), hostID: "mac-test",
                                                        targetID: RecipientTestRig.target, requestID: context.id))
        #expect(!(await asker.acceptsHostReply(wrongTarget)))
        #expect(await asker.acceptsHostReply(VoiceRouteRecordTests.reply(context)))
    }

    /// The route vanishes mid-handoff but the adapter's deliver itself succeeds: still no reply authority.
    @Test func aRouteThatVanishesWithoutAFailedHandoffLeavesNoAuthority() async throws {
        let rig = try await RecipientTestRig.make()
        let session = try await VoiceRouteRecordTests.session(rig)
        await rig.adapter.holdHandoff()
        let sending = Task { await session.receive(VoiceRouteRecordTests.tap("Other, check the build")) }
        await rig.adapter.waitForHandoff()
        await rig.adapter.setTargets([AdapterTarget(name: "reply", binding: "reply-binding")])
        await rig.adapter.releaseHandoff()
        let result = await sending.value
        guard case .error = try onlyControl(result) else { throw TestSupportError.expectedOneControl }
        let contexts = await rig.adapter.contexts
        #expect(contexts.count == 1 && contexts.allSatisfy { $0.binding.targetID == VoiceRouteRecordTests.other })
        #expect(!(await session.acceptsHostReply(VoiceRouteRecordTests.reply(try #require(contexts.last)))))
        #expect(await rig.adapter.legacy.isEmpty)
    }
}
#endif
