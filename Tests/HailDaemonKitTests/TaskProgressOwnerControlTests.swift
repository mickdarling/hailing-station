import Foundation
import Testing
@testable import HailDaemonKit

/// Real listener/session validation and router ownership; synthetic child, no model, microphone or output.
@Suite(.serialized, .timeLimit(.minutes(1))) struct TaskProgressOwnerControlTests {
    @Test(arguments: [false, true])
    func streamRetirementDuringValidationCannotApplyPause(replace: Bool) async throws {
        try await withTaskProgressOwnerRig { rig in
            let barrier = OwnerAdmissionTestBarrier()
            defer { barrier.release() }
            let fence = rig.controller.ownerState.fence
            let control = TaskProgressOwnerControlScope.$beforeValidation.withValue(
                { await barrier.hold($0) }, operation: { rig.control(.pause) }
            )
            defer { control.cancel() }
            var entered = barrier.entered.stream.makeAsyncIterator()
            _ = try #require(await entered.next())
            if replace { try await rig.startStream(UUID()) } else {
                rig.router.ambientAudio(.ended(stream: rig.stream, reason: .final))
                try #require(await eventually { rig.router.activeStream == nil })
            }
            barrier.release()
            #expect(await control.value == false)
            let report = await rig.status()
            #expect(report.task == rig.task && report.intervalSeconds == 60 && report.setBy == "agent")
            #expect(report.pauseReason != "ownerPaused")
            #expect(rig.controller.ownerState.fence === fence && fence.isOpen)
        }
    }

    @Test(arguments: [false, true])
    func queuedResumeCannotReopenAReplacementEnrollment(reuseID: Bool) async throws {
        try await withTaskProgressOwnerRig { rig in
            let barrier = OwnerAdmissionTestBarrier()
            defer { barrier.release() }
            _ = await rig.localOwner("pause updates", task: rig.task)
            let control = TaskProgressOwnerAdmissionScope.$beforeAdmission.withValue(
                { await barrier.hold($0) }, operation: { rig.control(.resume) }
            )
            defer { control.cancel() }
            var entered = barrier.entered.stream.makeAsyncIterator()
            _ = try #require(await entered.next())
            _ = await rig.listener.taskProgress(.init(action: .cancel, task: rig.task))
            let replacement = reuseID ? rig.task : UUID()
            try await rig.enroll(replacement, seconds: 120)
            _ = await rig.localOwner("pause updates", task: replacement)
            let fence = rig.controller.ownerState.fence
            try #require(!fence.isOpen)
            barrier.release()
            #expect(await control.value == false)
            let report = await rig.status()
            #expect(report.task == replacement && report.intervalSeconds == 120)
            #expect(report.pauseReason == "ownerPaused")
            #expect(rig.controller.ownerState.fence === fence && !fence.isOpen)
        }
    }

    @Test func anAdmittedOldControlCannotMutateANewerEnrollmentAfterReturning() async throws {
        try await withTaskProgressOwnerRig { rig in
            let barrier = OwnerAdmissionTestBarrier()
            defer { barrier.release() }
            let control = TaskProgressOwnerAdmissionScope.$afterAdmission.withValue({ task, result in
                #expect(result == .applied)
                await barrier.hold(task)
            }, operation: { rig.control(.stop) })
            defer { control.cancel() }
            var entered = barrier.entered.stream.makeAsyncIterator()
            _ = try #require(await entered.next())
            #expect(await rig.status().pauseReason == "ownerStopped")
            _ = await rig.listener.taskProgress(.init(action: .cancel, task: rig.task))
            try await rig.enroll(rig.task, seconds: 120)
            let fence = rig.controller.ownerState.fence
            barrier.release()
            #expect(await control.value, "the original operation was valid at its atomic admission")
            #expect(rig.controller.ownerState.fence === fence && fence.isOpen)
            let report = await rig.status()
            #expect(report.task == rig.task && report.intervalSeconds == 120 && report.setBy == "agent")
            #expect(report.pauseReason != "ownerStopped")
        }
    }

    @Test(arguments: [false, true]) func currentStreamOwnerControlsSurviveQuietOrMedia(media: Bool) async throws {
        try await withTaskProgressOwnerRig { rig in
            if media {
                _ = rig.router.setMedia(true, connection: rig.peer.connectionID, reason: "voice")
                try #require(rig.router.mediaMode(connection: rig.peer.connectionID))
            } else { _ = await rig.listener.sessionUpdate(.init(action: .quietOn)) }
            await rig.listener.refreshTaskProgressEnvironment()
            #expect(await rig.control(.interval(.seconds(90))).value)
            #expect(await rig.control(.stop).value)
            #expect(await rig.status().pauseReason == "ownerStopped")
            #expect(await rig.control(.resume).value)
            let report = await rig.status()
            #expect(report.intervalSeconds == 90 && report.setBy == "owner")
            #expect(report.pauseReason == (media ? "media" : "quiet"))
            #expect(rig.controller.ownerState.fence.isOpen)
        }
    }

    @Test func completedPauseRetiresCapturedOutputAndResumeNeverRenewsItsFence() async throws {
        try await withTaskProgressOwnerRig { rig in
            let generation = await rig.peer.hostRig.host.inputPolicyGeneration(for: RecipientTestRig.target)
            let fence = rig.controller.ownerState.fence
            let authority = TaskProgressPublicationAuthority(generation: generation, binding: "reply-binding",
                                                              taskFence: fence)
            try #require(authority.perform { true })
            #expect(await rig.control(.pause).value)
            #expect(!fence.isOpen)
            #expect(!authority.perform { true }, "no retained output can commit after pause returns")
            #expect(await rig.control(.resume).value)
            #expect(rig.controller.ownerState.fence !== fence && rig.controller.ownerState.fence.isOpen)
            #expect(!authority.perform { true }, "resume cannot reopen a previously captured publication fence")
        }
    }
}
