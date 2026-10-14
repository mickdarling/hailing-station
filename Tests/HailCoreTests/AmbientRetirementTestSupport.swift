import Foundation
import Testing
@testable import HailCore

@MainActor
final class AmbientRetirementBarrier {
    private var opened = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    var isHeld: Bool { !waiters.isEmpty }

    func wait() async {
        guard !opened else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func finish() {
        opened = true
        let waiting = waiters
        waiters.removeAll()
        waiting.forEach { $0.resume() }
    }
}

enum AmbientRetirementAction: Sendable {
    case stop, close, update
}

@MainActor
final class AmbientRetirementHarness {
    let center = NotificationCenter()
    let permission = AmbientRetirementBarrier()
    let factory = AmbientRetirementBarrier()
    let sending = AmbientRetirementBarrier()
    let release = AmbientRetirementBarrier()
    let gate = CoachingCaptureExclusion()
    let token = UUID()
    var holdsFactory = false
    var holdsPermission = false
    var holdsSends = false
    var captures: [FakeAudioCapture] = []
    var completions = 0
    var requestsJoining = 0
    var requestsFinished = 0
    lazy var controller = AmbientListeningController(
        notificationCenter: center,
        requestPermission: { [weak self] in
            guard let self else { return false }
            if holdsPermission { await permission.wait() }
            return true
        },
        makeStreamer: { [weak self] send in
            guard let self else { throw CancellationError() }
            if holdsFactory { await factory.wait() }
            let capture = FakeAudioCapture()
            captures.append(capture)
            return AmbientAudioStreamer(capture: capture, send: send)
        },
        releaseSession: { [release] in await release.wait() },
        sleep: { _ in try await Task.sleep(for: .seconds(60)) },
        send: { [weak self] _, _ in await self?.holdSend() }
    )

    func start() async throws {
        #expect(gate.claim(token))
        controller.onRetirementCompleted = { [weak self] in
            self?.completions += 1
            if let self { gate.release(token) }
        }
        await controller.turnOn(for: try binding())
    }

    /// Mirrors all explicit Mac admission release paths: the core action may have returned while already off.
    func retire(_ action: AmbientRetirementAction) async {
        switch action {
        case .stop: await controller.turnOff()
        case .close: await controller.destinationLost()
        case .update: await controller.update(binding: nil, scene: .background)
        }
        requestsJoining += 1
        await controller.waitForRetirement()
        requestsFinished += 1
        gate.release(token)
    }

    func interruption() {
        center.post(name: AVAudioEngineCapture.endedBySystem, object: nil, userInfo: [
            AVAudioEngineCapture.endedCauseKey: AVAudioEngineCapture.interruptionCause
        ])
    }

    private func holdSend() async {
        if holdsSends { await sending.wait() }
    }

    func unblock() { permission.finish(); factory.finish(); sending.finish(); release.finish() }

    func expectAdmissionHeld() {
        #expect(completions == 0)
        #expect(requestsFinished == 0)
        #expect(gate.isClaimed)
        #expect(!gate.claim(UUID()))
    }
}
