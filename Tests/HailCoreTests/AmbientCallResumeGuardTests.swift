import AVFAudio
import Foundation
import HailProtocol
import Testing
@testable import HailCore

@MainActor
@Suite(.serialized) struct AmbientCallResumeGuardTests {
    @Test func transportDropRetainsPausedIntentThroughBackgroundSelectionAndResume() async throws {
        let rig = try CallReconnectRig()
        try await rig.start()
        let old = try rig.currentBinding()
        try await rig.interrupt()
        try await rig.drop()
        await rig.controller.update(binding: nil, scene: .background)
        try await rig.reconnect()
        let fresh = try rig.currentBinding()
        try await callEventually { await MainActor.run { rig.controller.binding == fresh } }
        #expect(fresh.connectionGeneration != old.connectionGeneration)
        // A view update captured during selection may still carry nil after the transport is authorized.
        await rig.controller.update(binding: nil, scene: .background)
        #expect(rig.controller.isOn && !rig.controller.isListening && rig.capture.startCount == 1)
        rig.interruptionEnded()
        await rig.controller.update(binding: fresh, scene: .active)
        #expect(rig.controller.isListening && rig.capture.startCount == 2)
        try await rig.feed()
        try await callEventually { await MainActor.run { !rig.controller.reconnect.isPending } }
        #expect(rig.notices.map(\.outcome) == [.applied])
        await rig.close()
    }

    @Test(arguments: [0, 1, 2])
    func destinationLossTargetOrSelectionChangeStillEndsPause(change: Int) async throws {
        let rig = CallCaptureRig()
        let old = try binding()
        await rig.controller.turnOn(for: old)
        rig.interruption(true)
        try await callEventually { await MainActor.run {
            rig.controller.pausedReason != nil && !rig.controller.isListening
        } }
        let fresh: AmbientAudioBinding? = switch change {
        case 0: nil
        case 1: AmbientAudioBinding(hostID: old.hostID, targetID: "tmux:other",
                                   connectionGeneration: old.connectionGeneration, selection: old.selection)
        default: AmbientAudioBinding(hostID: old.hostID, targetID: old.targetID,
                                     connectionGeneration: old.connectionGeneration, selection: old.selection + 1)
        }
        await rig.controller.update(binding: fresh, scene: .active)
        #expect(!rig.controller.isOn && rig.controller.pausedReason == nil)
        rig.interruption(false)
        await rig.controller.update(binding: fresh, scene: .active)
        #expect(rig.fakes.count == 1)
        await rig.close()
    }

    @Test(arguments: [true, false])
    func latePrivateConfirmationCannotCrossOwnerStopOrPrivacyTap(stop: Bool) async throws {
        let rig = try CallReconnectRig()
        let timeout = BackoffSteps()
        rig.controller.reconnect.sleep = { await timeout.sleep($0) }
        try await rig.start()
        try await rig.confirmPrivacy()
        try await rig.interrupt()
        rig.interruptionEnded()
        try await callEventually { try await rig.socket.sentFrames().filter {
            $0.payload == .control(.setPrivacy(on: true))
        }.count == 2 }
        #expect(!rig.controller.isListening && rig.capture.startCount == 1)
        if stop { await rig.controller.turnOff() } else {
            try await rig.store.setPrivacy(on: false, host: rig.endpoint.id)
        }
        try await callEventually { await MainActor.run { !rig.controller.isOn } }
        try await rig.socket.push(.duckMode(on: true)) // Late reassertion confirmation.
        await rig.controller.update(binding: try rig.currentBinding(), scene: .active)
        await rig.microphoneRetry.release()
        #expect(!rig.controller.isOn && rig.capture.startCount == 1)
        await rig.close()
        await timeout.release()
    }

    @Test(arguments: [false, true])
    func failedPrivateConfirmationNeverOpensTheMicrophone(timeout: Bool) async throws {
        let rig = try CallReconnectRig()
        let deadline = BackoffSteps()
        rig.controller.reconnect.sleep = { await deadline.sleep($0) }
        try await rig.start()
        try await rig.confirmPrivacy()
        try await rig.interrupt()
        rig.interruptionEnded()
        try await callEventually { try await rig.socket.sentFrames().filter {
            $0.payload == .control(.setPrivacy(on: true))
        }.count == 2 }
        if timeout {
            try await callEventually { await deadline.pending == 1 }
            rig.clock.advance(by: .seconds(5))
            await deadline.release()
        } else { try await rig.socket.push(.duckMode(on: false)) }
        try await callEventually { await MainActor.run { !rig.controller.isOn } }
        #expect(!rig.controller.isListening && rig.capture.startCount == 1)
        #expect(try await rig.socket.sentFrames().allSatisfy {
            if case .audio = $0.payload { return false }; return true
        })
        await rig.close()
        await deadline.release()
    }

    @Test func routeReconfigurationDuringTheWindowDoesNotPreemptTheCall() async throws {
        let rig = CallCaptureRig()
        await rig.controller.turnOn(for: try binding())
        rig.route(4)
        try await callEventually { await rig.routeWait.pending == 1 }
        rig.routeEvaluated = false
        rig.fakes[0].running = false
        rig.center.post(name: .AVAudioEngineConfigurationChange, object: rig.engines[0])
        try await callEventually { await MainActor.run { rig.routeEvaluated } }
        rig.interruption(true)
        try await callEventually { await MainActor.run {
            rig.controller.pausedReason != nil && !rig.controller.isListening
        } }
        rig.interruption(false)
        try await callEventually { await MainActor.run { rig.controller.isListening } }
        await rig.close()
    }
}
