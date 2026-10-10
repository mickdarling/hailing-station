import Foundation
import HailProtocol
import Testing
@testable import HailCore

/// #366 on the device: the status text for each side of an ambient take-over, and how the toggle reaches it.
@Suite struct AmbientHandoffTextTests {
    @Test func theDeviceThatLostListeningIsToldWhereItWentByClassOnly() {
        #expect(AmbientHandoff.movedAway(to: "pad").status == "Listening moved to iPad")
        #expect(AmbientHandoff.movedAway(to: "phone").status == "Listening moved to iPhone")
        #expect(AmbientHandoff.movedAway(to: "mac").status == "Listening moved to Mac")
        #expect(AmbientHandoff.movedAway(to: nil).status == "Listening moved to another device")
        #expect(AmbientHandoff.movedAway(to: "Mick's iPad").status == "Listening moved to another device")
        #expect(AmbientHandoff.listenHereTitle == "Listen here")
        #expect(AmbientHandoff.movedAway(to: "pad").accessibilityLabel
            == "Listening moved to iPad. Tap Listen here to listen on this device instead.")
    }

    @Test func theDeviceThatTookListeningOverConfirmsItCalmly() {
        #expect(AmbientHandoff.movedHere(from: "phone").status == "Listening here now (moved from iPhone)")
        #expect(AmbientHandoff.movedHere(from: "pad").status == "Listening here now (moved from iPad)")
        #expect(AmbientHandoff.movedHere(from: nil).status == "Listening here now")
        #expect(AmbientHandoff.movedHere(from: nil).accessibilityLabel == "Listening here now")
    }

    @Test @MainActor func onlyATakeOverRefusalIsAMove() {
        #expect(AmbientHandoff(refusal: HostConnectionFailure.remote("not_allowed: ambient moved to pad"))
            == .movedAway(to: "pad"))
        #expect(AmbientHandoff(refusal: HostConnectionFailure.remote("not_allowed: ambient moved to another device"))
            == .movedAway(to: nil))
        for other: any Error in [
            HostConnectionFailure.remote("not_allowed: ambient busy"),
            HostConnectionFailure.remote("malformed: ambient moved to pad"),
            HostConnectionFailure.remote("not_allowed: ambient stopped: listener exited"),
            HostConnectionFailure.remote("ambient moved to pad"),
            HostConnectionFailure.notReady,
            HostConnectionFailure.malformed("ambient moved to pad")
        ] {
            #expect(AmbientHandoff(refusal: other) == nil)
        }
        // A move is final: the toggle never retries its way back into a ping-pong.
        #expect(!AmbientListeningController.isTransient(
            HostConnectionFailure.remote("not_allowed: ambient moved to pad")
        ))
    }

    @Test func thisDeviceGivesItsClassOnly() {
        #expect(AmbientHandoff.localDeviceKind.map { AmbientTakeOver.deviceKinds.contains($0) } ?? true)
    }
}

@MainActor
@Suite struct AmbientHandoffControllerTests {
    @MainActor
    final class Harness {
        let capture = FakeAudioCapture()
        var refusal: (any Error)?
        var unexpectedStops: [String] = []
        var waits = 0
        var holdsConfirmation = true
        lazy var controller: AmbientListeningController = {
            let controller = AmbientListeningController(
                requestPermission: { true },
                // Weak (#394): the controller can call back after a test has returned and freed the harness.
                makeStreamer: { [capture] send in AmbientAudioStreamer(capture: capture, send: send) },
                releaseSession: {},
                sleep: { [weak self] _ in try await self?.wait() },
                send: { [weak self] _, _ in try await self?.record() }
            )
            controller.onUnexpectedStop = { [weak self] in self?.unexpectedStops.append($0) }
            return controller
        }()

        func record() throws { if let refusal { throw refusal } }

        func wait() async throws {
            waits += 1
            while holdsConfirmation { try await Task.sleep(for: .milliseconds(5)) }
        }

        func feed(until done: @MainActor () -> Bool) async throws {
            for index in 0..<400 where !done() {
                try capture.yield(sineBuffer(offset: index * 4_800))
                try await Task.sleep(for: .milliseconds(5))
            }
            #expect(done())
        }
    }

    @Test func movedAwayTurnsTheToggleOffCalmlyAndListenHereTakesItBack() async throws {
        let harness = Harness()
        let current = try binding()
        harness.refusal = HostConnectionFailure.remote("not_allowed: ambient moved to pad")
        await harness.controller.turnOn(for: current)
        try await harness.feed { !harness.controller.isOn }
        #expect(!harness.controller.isListening)
        #expect(harness.controller.handoff == .movedAway(to: "pad"))
        #expect(harness.controller.stopReason == "Listening moved to iPad")
        // Not an error: no "stopped listening" alert, and no "host ended listening" text.
        #expect(harness.unexpectedStops.isEmpty)
        #expect(harness.controller.stopReason?.contains("host ended") == false)

        // "Listen here" simply starts listening again on this device.
        harness.refusal = nil
        await harness.controller.turnOn(for: current)
        #expect(harness.controller.isListening)
        #expect(harness.controller.handoff == nil)
        #expect(harness.controller.stopReason == nil)
        await harness.controller.turnOff()
        #expect(harness.controller.handoff == nil)
    }

    @Test func anyOtherRefusalIsStillAnUnexpectedStop() async throws {
        let harness = Harness()
        harness.refusal = HostConnectionFailure.remote("not_allowed: ambient busy")
        await harness.controller.turnOn(for: try binding())
        try await harness.feed { !harness.controller.isOn }
        #expect(harness.controller.handoff == nil)
        #expect(harness.unexpectedStops.count == 1)
    }

    @Test func movedHereShowsABriefConfirmationForThisHostOnly() async throws {
        let harness = Harness()
        let current = try binding()
        harness.controller.movedHere(from: "phone", host: current.hostID)
        #expect(harness.controller.handoff == nil)

        await harness.controller.turnOn(for: current)
        harness.controller.movedHere(from: "phone", host: try endpoint("mac-2").id)
        #expect(harness.controller.handoff == nil)
        harness.controller.movedHere(from: "phone", host: current.hostID)
        #expect(harness.controller.handoff == .movedHere(from: "phone"))
        #expect(harness.controller.handoff?.status == "Listening here now (moved from iPhone)")
        #expect(harness.controller.isListening)

        try await waitUntil { await MainActor.run { harness.waits == 1 } }
        harness.holdsConfirmation = false
        try await waitUntil { await MainActor.run { harness.controller.handoff == nil } }
        #expect(harness.controller.isListening)
        await harness.controller.turnOff()
    }

    @Test func turningOffClearsTheConfirmation() async throws {
        let harness = Harness()
        let current = try binding()
        await harness.controller.turnOn(for: current)
        harness.controller.movedHere(from: nil, host: current.hostID)
        #expect(harness.controller.handoff == .movedHere(from: nil))
        await harness.controller.turnOff()
        #expect(harness.controller.handoff == nil)
        harness.holdsConfirmation = false
    }
}
