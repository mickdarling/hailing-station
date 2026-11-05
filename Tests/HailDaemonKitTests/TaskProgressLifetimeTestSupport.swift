import Foundation
import HailProtocol
import Synchronization
import Testing
@testable import HailDaemonKit

final class LifetimeWakeCounter: Sendable {
    private let value = Mutex(0)
    var count: Int { value.withLock { $0 } }
    func note() { value.withLock { $0 += 1 } }
}

enum LifetimeWakeFailure: CaseIterable, Sendable {
    case generic, refusal
    var error: any Error {
        switch self {
        case .generic: ProviderCoordinatorSyntheticError.arbitraryFailure
        case .refusal: AdapterError.inputPending(.tainted)
        }
    }
}

enum LifetimeSuccessor: CaseIterable, Sendable, Equatable {
    case same, binding, target

    func replace(_ rig: TaskProgressOwnerControlRig) async throws -> String {
        _ = await rig.listener.taskProgress(.init(action: .cancel, task: rig.task))
        let target = self == .target ? "recipient:other" : RecipientTestRig.target
        if self == .binding {
            await rig.peer.hostRig.adapter.setTargets([
                .init(name: "reply", binding: "replacement-binding"), .init(name: "other", binding: "other-binding")
            ])
            _ = try await rig.peer.hostRig.host.allow(target, tier: .open)
        }
        _ = await rig.peer.session.receive(sessionFrame(payload: .control(.select(targetID: target))))
        try await rig.startStream(UUID())
        let report = await rig.listener.taskProgress(.init(action: .start, target: target,
                                                          task: rig.task, seconds: 120))
        try #require(report.task == rig.task && report.intervalSeconds == 120)
        return target
    }
}

func withLifetimeWakeRig(
    _ operation: (TaskProgressOwnerControlRig, LifetimeWakeCounter) async throws -> Void
) async throws {
    let finished = LifetimeWakeCounter()
    try await TaskProgressWakeScope.$didFinishWake.withValue({ finished.note() }, operation: {
        try await withTaskProgressOwnerRig { try await operation($0, finished) }
    })
}

func lifetimePromptToken(_ prompt: String) throws -> UUID {
    let pieces = prompt.components(separatedBy: "--token ")
    return try #require(pieces.last?.split(separator: " ").first.flatMap { UUID(uuidString: String($0)) })
}

func assertLifetimeSuccessor(_ rig: TaskProgressOwnerControlRig, target: String,
                             fence: TaskProgressOutputFence) async throws {
    let status = await rig.status()
    #expect(status.task == rig.task && status.session == target && status.intervalSeconds == 120)
    #expect(status.setBy == "agent" && status.pauseReason != "ownerStopped")
    #expect(rig.controller.ownerState.fence === fence && fence.isOpen)
    let policy = await rig.peer.hostRig.host.inputPolicyGeneration(for: target)
    let binding = try #require(policy.binding)
    let authority = TaskProgressPublicationAuthority(generation: policy, binding: binding, taskFence: fence)
    #expect(authority.isCurrent, "the successor's actual retained task/input policy must stay live")
}
