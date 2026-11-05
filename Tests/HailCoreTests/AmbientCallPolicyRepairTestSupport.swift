import Foundation
import HailProtocol
import Testing
@testable import HailCore

/// Every exit releases constructor/backoff gates and attempts bounded cleanup, including assertion failures.
@MainActor
func withCallPolicyRepairRig(
    _ operation: @escaping @MainActor (CallReconnectRig) async throws -> Void
) async throws {
    let rig = try CallReconnectRig()
    let result: Result<Void, any Error>
    do {
        try await ambientRefusalDeadline(timeout: .seconds(40)) { try await operation(rig) }
        result = .success(())
    } catch { result = .failure(error) }
    rig.beforeMakeStreamerReturn = nil
    await rig.activationGate?.fire()
    await rig.microphoneRetry.release()
    // A non-cooperative operation can retain only this fixture; it cannot hold the test task indefinitely.
    do { try await ambientRefusalDeadline { await rig.close() } } catch { Issue.record(error) }
    try result.get()
}

@MainActor
func pauseForPolicyRepair(_ rig: CallReconnectRig) async throws {
    let released = rig.released
    rig.center.post(name: AVAudioEngineCapture.endedBySystem, object: nil, userInfo: [
        AVAudioEngineCapture.endedCauseKey: AVAudioEngineCapture.interruptionCause
    ])
    try await waitUntil { @MainActor in rig.controller.pausedReason != nil && rig.released > released }
}

@MainActor
func deliverAddressedPolicyNotice(target: String?, to rig: CallReconnectRig) async throws {
    let frame = Frame(timestamp: 1, target: target, source: "haild",
                      payload: .control(.error(code: .notAllowed, message: "ambient target_policy_changed")))
    try await rig.socket.push(FrameCoding.encode(frame))
    // Socket processing is ordered; do not infer completion merely from yielding to the receiver.
    let barrier = TargetInfo(id: "tmux:repair-barrier", kind: "tmux", name: "Barrier", alive: true)
    let targets = rig.store.snapshots[rig.endpoint.id]?.targets ?? [rig.target]
    try await rig.socket.push(.targets(targets + [barrier]))
    try await waitUntil { @MainActor in rig.store.snapshots[rig.endpoint.id]?.targets.contains(barrier) == true }
}
