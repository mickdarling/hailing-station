import Foundation
import Testing
@testable import HailDaemonKit

struct TaskProgressOwnerControlRig {
    let fake: FakeRightyo
    let router: AmbientRightyoRouter
    let peer: SessionUpdateListenerRig
    let controller: ListenerTaskProgress
    let task: UUID
    let stream: UUID
    let clock: ProgressTestClock
    var listener: WebSocketListener { peer.listener }

    static func make() async throws -> Self {
        let fake = try FakeRightyo("/bin/cat > /dev/null")
        let router = AmbientRightyoRouter(configuration: .init(executable: fake.executable, config: fake.config,
            target: RecipientTestRig.target, binding: "reply-binding", allowSynthetic: true,
            timing: .init(eofGrace: 0.1, termGrace: 0.2), replyControl: false))
        var listener: WebSocketListener?
        do {
            let peer = try await SessionUpdateListenerRig.make(ambient: router)
            listener = peer.listener
            let clock = ProgressTestClock()
            await peer.listener.enableTaskProgress(clock: clock.clock)
            let controller = try #require(await peer.listener.taskProgressController)
            let value = Self(fake: fake, router: router, peer: peer, controller: controller,
                             task: UUID(), stream: UUID(), clock: clock)
            try await value.startStream(value.stream)
            try await value.enroll(value.task, seconds: 60)
            return value
        } catch {
            if let listener { await listener.stop() } else { await router.shutdown() }
            fake.cleanUp()
            throw error
        }
    }

    func startStream(_ stream: UUID) async throws {
        let selection = await peer.session.selectionGeneration
        let policy = await peer.hostRig.host.inputPolicyGeneration(for: RecipientTestRig.target)
        let binding = try #require(policy.binding)
        router.ambientAudio(.admittedStart(stream: stream, connection: peer.connectionID,
            target: RecipientTestRig.target, selection: selection, binding: binding, policy: policy))
        try #require(await eventually { router.activeStream == stream })
        await router.taskProgressChanges.queued({}).value
    }

    func enroll(_ task: UUID, seconds: Int) async throws {
        let report = await listener.taskProgress(.init(action: .start, target: RecipientTestRig.target,
                                                      task: task, seconds: seconds))
        try #require(report.task == task && report.intervalSeconds == seconds)
    }

    func status() async -> LocalTaskProgressReport { await listener.taskProgress(.init(action: .status)) }

    func control(_ control: TaskProgressOwnerControl) -> Task<Bool, Never> {
        let listener = listener, connection = peer.connectionID, stream = stream
        return Task { await listener.taskProgressOwner(control, connection: connection, stream: stream) }
    }

    func localOwner(_ command: String, task: UUID) async -> LocalTaskProgressReport {
        await listener.taskProgress(.init(action: .owner, task: task, command: command))
    }

    func close() async {
        await peer.hostRig.adapter.releaseLegacyHandoff()
        await peer.hostRig.adapter.releaseListing()
        await listener.stop()
        fake.cleanUp()
    }
}

func withTaskProgressOwnerRig(_ operation: (TaskProgressOwnerControlRig) async throws -> Void) async throws {
    let rig = try await TaskProgressOwnerControlRig.make()
    do {
        try await operation(rig)
        await rig.close()
    } catch {
        await rig.close()
        throw error
    }
}
