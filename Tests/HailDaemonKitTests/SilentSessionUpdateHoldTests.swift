import Foundation
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1))) struct SilentSessionUpdateHoldTests {
    @Test func quietRetainsCardsAndClearDrainsImmediately() async throws {
        let mode = "quiet"
        let router = makeRouter(), rig = try await SilentUpdateRig.make(ambient: router)
        await set(mode, on: true, rig: rig, router: router)
        #expect(await rig.submit().outcome == .held && rig.sends == 0)
        #expect(await rig.listener.sessionUpdate(.init(action: .status)).held == 1)
        await set(mode, on: false, rig: rig, router: router)
        #expect(await eventually { await rig.listener.sessionUpdate(.init(action: .status)).held == 0 })
        #expect(rig.sends == 1 && rig.drains.contains("trigger=hold_cleared count=1"))
        await rig.listener.stop()
    }

    @Test(arguments: ["privacy", "meeting", "media"])
    func roomModesDoNotHoldSilentInfo(_ mode: String) async throws {
        let router = makeRouter(), rig = try await SilentUpdateRig.make(ambient: router)
        await set(mode, on: true, rig: rig, router: router)
        #expect(await rig.submit().outcome == .delivered && rig.sends == 1)
        await rig.listener.stop()
    }

    @Test(arguments: ["privacy", "meeting", "media"])
    func roomModesWaitOnlyForStreamingReplyTerminal(_ mode: String) async throws {
        let router = makeRouter(), rig = try await SilentUpdateRig.make(ambient: router), reply = UUID()
        await set(mode, on: true, rig: rig, router: router)
        try await rig.send(rig.frame(reply, text: true))
        #expect(await rig.submit().outcome == .held && rig.sends == 1)
        try await rig.send(rig.frame(reply))
        #expect(rig.sends == 2)
        try await rig.send(rig.frame(reply, final: true))
        #expect(await eventually { await rig.listener.sessionUpdate(.init(action: .status)).held == 0 })
        #expect(rig.sends == 4)
        await rig.listener.stop()
    }

    @Test(arguments: ["privacy", "meeting", "media"])
    func roomModeEntryAtFinalPeerHopDoesNotHoldSilentInfo(_ mode: String) async throws {
        let router = makeRouter(), rig = try await SilentUpdateRig.make(ambient: router)
        let report = await SessionUpdatePrivacyScope.$beforePeerHop.withValue({
            await set(mode, on: true, rig: rig, router: router)
        }, operation: { await rig.submit() })
        #expect(report.outcome == .delivered && rig.sends == 1)
        await rig.listener.stop()
    }

    @Test func privacyEntryDuringSubmissionDoesNotDiscardSilentInfo() async throws {
        let router = makeRouter(), rig = try await SilentUpdateRig.make(ambient: router)
        let report = await SessionUpdatePrivacyScope.$beforeAuthorityValidation.withValue({
            await set("privacy", on: true, rig: rig, router: router)
        }, operation: { await rig.submit() })
        #expect(report.outcome == .delivered && rig.sends == 1)
        await rig.listener.stop()
    }

    @Test(arguments: ["privacy", "meeting", "quiet"])
    func configuredSpeechKeepsMainModeBehavior(_ mode: String) async throws {
        let router = makeRouter(), rig = try await SilentUpdateRig.make(ambient: router)
        await rig.listener.configureSessionUpdateSpeech(UnusedUpdateSpeech())
        #expect(await rig.submit().outcome == .held)
        await set(mode, on: true, rig: rig, router: router)
        // Main holds configured info on submit in meeting mode; its existing drain triggers are unchanged.
        if mode != "meeting" {
            #expect(await rig.listener.drainSessionUpdates(.interaction).isEmpty && rig.sends == 0)
        }
        let report = await rig.submit()
        #expect(report.outcome == (mode == "privacy" ? .dropped : .held) && rig.sends == 0)
        #expect(report.held == (mode == "privacy" ? 0 : 2))
        await rig.listener.stop()
    }

    @Test func configuredSpeechPrivacyAtFinalEnqueueRefusesCard() async throws {
        let rig = try await SilentUpdateRig.make()
        await rig.listener.configureSessionUpdateSpeech(UnusedUpdateSpeech())
        let hold = await rig.listener.replyHold, fence = await rig.listener.sessionUpdateFence
        hold.set(true, connection: rig.connection)
        let update = try #require(SessionUpdate(session: RecipientTestRig.target, priority: .info,
            spoken: "Synthetic spoken-mode card", submitted: .now))
        let audience = SessionUpdateAudienceLease(lastInput: nil, privacyRevision: hold.entryRevision)
        #expect(await !rig.peer.deliverSessionUpdate(update, audience: audience, hold: hold,
                                                   ambient: nil, fence: fence))
        #expect(rig.sends == 0)
        await rig.listener.stop()
    }

    @Test func quietAtFinalPeerHopRefusesSendAndClearDuringReplyWaitsForTerminal() async throws {
        let mode = "quiet"
        let router = makeRouter(), rig = try await SilentUpdateRig.make(ambient: router), reply = UUID()
        let report = await SessionUpdatePrivacyScope.$beforePeerHop.withValue({
            await set(mode, on: true, rig: rig, router: router)
        }, operation: { await rig.submit() })
        #expect(report.outcome == .held && rig.sends == 0)
        try await rig.send(rig.frame(reply, text: true))
        await set(mode, on: false, rig: rig, router: router)
        // Join a real drain at the cleared hold while the stream still owns the transport.
        await rig.listener.drainSilentSessionUpdates(.holdCleared)
        #expect(rig.sends == 1)
        try await rig.send(rig.frame(reply, final: true))
        #expect(await eventually { await rig.listener.sessionUpdate(.init(action: .status)).held == 0 })
        #expect(rig.sends == 3)
        await rig.listener.stop()
    }

    private func makeRouter() -> AmbientRightyoRouter {
        AmbientRightyoRouter(configuration: .init(executable: URL(fileURLWithPath: "/bin/false"),
            config: URL(fileURLWithPath: "/dev/null"), target: RecipientTestRig.target, binding: "reply-binding"))
    }

    private func set(_ mode: String, on: Bool, rig: SilentUpdateRig, router: AmbientRightyoRouter) async {
        switch mode {
        case "quiet":
            if on { _ = await rig.listener.sessionUpdate(.init(action: .quietOn)) } else {
                await rig.listener.setSyntheticQuiet(false)
            }
        case "meeting":
            _ = router.setMeeting(on: on, connection: rig.connection, reason: "synthetic")
            #expect(router.state.withLock { ($0.meeting[rig.connection] != nil) == on })
        case "media":
            _ = router.setMedia(on, connection: rig.connection, reason: "synthetic")
            #expect(router.mediaMode(connection: rig.connection) == on)
        default:
            let hold = await rig.listener.replyHold
            hold.set(on, connection: rig.connection)
            // Keep router privacy and the global reply hold in sync without launching a reporting child.
            router.state.withLock { state in
                state.duck[rig.connection] = on ? AmbientDuckTimer(token: UUID(), timer: nil) : nil
            }
        }
    }
}
