import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

@Suite(.serialized, .timeLimit(.minutes(1))) struct SilentSessionUpdateTests {
    @Test func silentInfoDeliversOnSubmitAndLogsNoContent() async throws {
        let rig = try await SilentUpdateRig.make()
        #expect(await rig.submit().outcome == .delivered)
        #expect(rig.sends == 1 && rig.drains == ["trigger=immediate count=1"])
        #expect(await rig.listener.sessionUpdate(.init(action: .status)).held == 0)
        await rig.listener.stop()
    }

    @Test(arguments: ["request", "turn", "playback"])
    func inputAndDevicePlaybackDoNotHoldSilentCards(_ activity: String) async throws {
        let rig = try await SilentUpdateRig.make()
        switch activity {
        case "request": _ = try await rig.host.submit(on: rig.session)
        case "turn":
            _ = await rig.session.authorize(sessionFrame(target: RecipientTestRig.target,
                payload: .text(TextPayload(text: "Synthetic final turn"))), device: "synthetic")
        default: await rig.session.syntheticPlayback()
        }
        #expect(await rig.submit().outcome == .delivered && rig.sends == 1)
        await rig.listener.stop()
    }

    @Test func configuredSpeechKeepsMainInfoAndActionBehavior() async throws {
        let rig = try await SilentUpdateRig.make()
        await rig.listener.configureSessionUpdateSpeech(UnusedUpdateSpeech())
        #expect(await rig.submit().outcome == .held && rig.sends == 0)
        #expect(await rig.listener.drainSessionUpdates(.naturalPause).count == 1 && rig.sends == 1)
        #expect(await rig.submit(.action).outcome == .delivered && rig.sends == 2)
        await rig.listener.stop()
    }

    @Test func actionCardStillDeliversImmediatelyDuringReply() async throws {
        let rig = try await SilentUpdateRig.make(), reply = UUID()
        try await rig.send(rig.frame(reply, text: true))
        #expect(await rig.submit(.action).outcome == .delivered && rig.sends == 2)
        await rig.listener.stop()
    }

    @Test func connectionClosedWithPendingCardNeverDelivers() async throws {
        let rig = try await SilentUpdateRig.make(), reply = UUID()
        await rig.listener.setSyntheticQuiet(true)
        #expect(await rig.submit().outcome == .held)
        let terminal = try #require(await rig.peer.prepareReplyPublication(rig.frame(reply, final: true)))
        await rig.peer.finish(reason: "synthetic closed")
        #expect(!terminal.enqueue())
        await rig.listener.setSyntheticQuiet(false)
        await rig.listener.drainSilentSessionUpdates(.immediate)
        #expect(rig.sends == 0)
        await rig.listener.stop()
    }
}

extension HostSession {
    func syntheticPlayback() { repliesInFlight = [UUID()] }
}
