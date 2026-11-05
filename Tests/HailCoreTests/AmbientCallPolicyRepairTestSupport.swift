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

/// An already-decoded notice may enter the store after another stream/selection has replaced its origin.
@MainActor
func deliverCallPolicyCallback(
    _ message: String, origin: (generation: UUID?, stream: UUID?), target: String?, to rig: CallReconnectRig
) -> Bool {
    let event = HostReplyEvent(endpointID: rig.endpoint.id, frame: Frame(timestamp: 1, target: target,
        source: "haild", payload: .control(.error(code: .notAllowed, message: message))))
    return HostNoticeOrigin.$generation.withValue(origin.generation) {
        HostNoticeOrigin.$streamID.withValue(origin.stream) { rig.store.receiveAmbientNotice(event) }
    }
}

struct CallPolicyRunOrigins {
    let oldBinding: AmbientAudioBinding
    let oldStream: UUID
    let freshBinding: AmbientAudioBinding
}

@MainActor
func prepareNewCallPolicyRun(
    _ rig: CallReconnectRig, sameTarget: Bool, sentPCM: Bool
) async throws -> CallPolicyRunOrigins {
    try await rig.start()
    try await rig.feed()
    try await waitUntil { try await !audioFrames(rig.socket).isEmpty }
    let old = try rig.currentBinding()
    let frame = try #require(try await audioFrames(rig.socket).last)
    guard case .audio(let audio) = frame.payload else { throw CancellationError() }
    let stream = try #require(audio.streamID)
    await rig.controller.turnOff()
    let target = sameTarget ? rig.target
        : TargetInfo(id: "tmux:second", kind: "tmux", name: "Second", alive: true)
    try await rig.socket.push(.targets([rig.target, target]))
    try await waitUntil { @MainActor in rig.store.snapshots[rig.endpoint.id]?.targets.contains(target) == true }
    try await rig.select(restoring: false, targetID: target.id)
    let fresh = try #require(rig.store.ambientBinding(host: rig.endpoint.id, targetID: target.id))
    #expect(fresh.selection != old.selection)
    await rig.controller.turnOn(for: fresh)
    if sentPCM {
        let before = try await audioFrames(rig.socket).count
        try await rig.feed()
        try await waitUntil { try await audioFrames(rig.socket).count > before }
    }
    return CallPolicyRunOrigins(oldBinding: old, oldStream: stream, freshBinding: fresh)
}
