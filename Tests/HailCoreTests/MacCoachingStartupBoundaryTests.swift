#if os(macOS)
import Foundation
import Testing
@testable import HailCore

@MainActor final class MacLateStartingCapture: AudioCapturing {
    let base = FakeAudioCapture()
    var onStart: (() -> Void)?
    func start() throws -> AsyncStream<AudioCaptureBuffer> {
        onStart?() // Cancellation can precede completion of the resource-installing call.
        return try base.start()
    }
    func stop() { base.stop() }
}

@Suite @MainActor struct MacCoachingStartupBoundaryTests {
    @Test(arguments: [4, 6])
    func cancellationInsideFinalRunningGetterCannotAdmitOrPublish(atRead: Int) throws {
        let capture = FakeAudioCapture()
        var running = false
        var reads = 0
        var owner: MacCoachingAudioOwner?
        owner = .init(input: .init(deviceID: 10, uid: "authored-input", streams: [11]), capture: capture,
            output: .init(start: { running = true }, stop: { running = false }, running: {
                reads += 1
                let observed = running
                if reads == atRead { owner?.stop() }
                return observed
            }), bound: { true })
        let active = try #require(owner)
        #expect(throws: CoachingSafetyError.unsafeOutput) { _ = try active.start() }
        #expect(capture.startCount == (atRead == 4 ? 0 : 1))
        #expect(!running && capture.stopCount == 1)
        owner = nil
    }

    @Test func cancelledStartupRetainsResponsibilityForLateCaptureInstallation() throws {
        let capture = MacLateStartingCapture()
        var running = false
        let owner = MacCoachingAudioOwner(
            input: .init(deviceID: 10, uid: "authored-input", streams: [11]), capture: capture,
            output: .init(start: { running = true }, stop: { running = false }, running: { running }),
            bound: { true })
        capture.onStart = {
            owner.stop()
            #expect(throws: CoachingSafetyError.unsafeOutput) { _ = try owner.start() }
        }
        #expect(throws: CoachingSafetyError.unsafeOutput) { _ = try owner.start() }
        #expect(!running && capture.base.startCount == 1 && capture.base.stopCount == 2)
        capture.onStart = nil
        _ = try owner.start() // The late resource must have been cleaned before a fresh explicit start.
        owner.stop()
    }

    @Test func cancelledStartupCleansLateOutputBeforePermittingExplicitRestart() throws {
        let capture = FakeAudioCapture()
        var running = false
        var stops = 0
        var hook: (() -> Void)?
        let owner = MacCoachingAudioOwner(
            input: .init(deviceID: 10, uid: "authored-input", streams: [11]), capture: capture,
            output: .init(start: { hook?(); running = true }, stop: { stops += 1; running = false },
                          running: { running }), bound: { true })
        hook = {
            owner.stop()
            #expect(throws: CoachingSafetyError.unsafeOutput) { _ = try owner.start() }
        }
        #expect(throws: CoachingSafetyError.unsafeOutput) { _ = try owner.start() }
        #expect(!running && stops == 2 && capture.startCount == 0 && capture.stopCount == 2)
        hook = nil
        _ = try owner.start()
        owner.stop()
        #expect(!running && capture.startCount == 1 && capture.stopCount == 3)
    }
}
#endif
