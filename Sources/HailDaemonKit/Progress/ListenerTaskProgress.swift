import Foundation

// Enrollment, deadline commits and listener wiring share the same private state owner.
// swiftlint:disable file_length

private struct TaskProgressWakeContext: Sendable {
    let generation: TargetPolicyGeneration
    let attempt: TaskProgressWakeAttempt
    let lifetime: TaskProgressAdmissionLifetime
    let revision: UInt64
    let fence: TaskProgressOutputFence
}

struct TaskProgressEnrollmentAdmission: TaskProgressOwnerAdmission {
    let state: TaskProgressOwnerState
    let lease: TaskProgressOwnerLease
    let lifetime: TaskProgressOwnerLifetime
    func perform(_ commit: () -> TaskProgressControlResult) -> TaskProgressControlResult {
        state.withCurrent(lease) { lifetime.perform(commit) }
    }
}

enum TaskProgressOwnerSource: Sendable {
    case local
    case ambient(any AmbientListenerWiring, TaskProgressAmbientAudience)
    func perform(_ commit: () -> TaskProgressControlResult) -> TaskProgressControlResult {
        switch self {
        case .local: commit()
        case .ambient(let wiring, let audience): wiring.withTaskProgressOwnerPermission(audience, commit: commit)
        }
    }
}

struct TaskProgressRetainedOwnerAdmission: TaskProgressOwnerAdmission {
    let state: TaskProgressOwnerState
    let lease: TaskProgressOwnerLease
    let lifetime: TaskProgressOwnerLifetime
    let source: TaskProgressOwnerSource
    let control: TaskProgressOwnerControl
    func perform(_ commit: () -> TaskProgressControlResult) -> TaskProgressControlResult {
        state.perform(lease, control: control) { lifetime.perform { source.perform(commit) } }
    }
}

/// The listener owns enrollment, current policy and recipient admission. The scheduler owns only deadlines.
/// A task never acquires voice reply ownership, renews a request, interrupts a turn or restarts a provider.
actor ListenerTaskProgress {
    private weak var listener: WebSocketListener?
    private let host: HailHost
    private let clock: TaskProgressClock
    private var scheduler: TaskProgressScheduler?
    private var generation: TargetPolicyGeneration?
    private var enrollment: TaskProgressTask?
    private var expires: ContinuousClock.Instant?
    private var lastText: String?
    private var outstandingPrivacyRevision: UInt64?
    nonisolated let ownerState = TaskProgressOwnerState()
    private var outputFence: TaskProgressOutputFence { ownerState.fence }
    private let ownerLifetime: TaskProgressOwnerLifetime
    private var outstandingOutputFence: TaskProgressOutputFence?
    private var outstandingWake: TaskProgressWake?
    private var handling = false

    init(listener: WebSocketListener, host: HailHost, clock: TaskProgressClock = .continuous,
         ownerLifetime: TaskProgressOwnerLifetime) {
        (self.listener, self.host, self.clock, self.ownerLifetime) = (listener, host, clock, ownerLifetime)
    }

    private func timer() -> TaskProgressScheduler {
        if let scheduler { return scheduler }
        let value = TaskProgressScheduler(clock: clock) { [weak self] in await self?.wake($0) }
        scheduler = value
        return value
    }

    func handle(_ request: LocalTaskProgressRequest) async -> LocalTaskProgressReport {
        // Serialize mutations across registry/policy/transport awaits; status is always inspectable.
        if request.action == .status { return await status() }
        guard !handling else { return .init(outcome: "refused", reason: "busy") }
        handling = true
        defer { handling = false }
        if request.action == .start { return await start(request) }
        guard let task = enrollment, request.task == task.id, let lease = ownerState.lease(for: task) else {
            return .init(outcome: "refused", reason: "no_matching_task")
        }
        let scheduler = timer()
        switch request.action {
        case .start, .status: return .init(outcome: "refused", reason: "invalid")
        case .interval:
            return await controlled(await scheduler.agent(interval: .seconds(request.seconds ?? 0)))
        case .owner: return await ownerRequest(request)
        case .cancel:
            await finish(lease)
            return await status()
        case .finish: return await finishRequest(request, lease: lease)
        case .report: return await report(request)
        }
    }

    private func finishRequest(_ request: LocalTaskProgressRequest, lease: TaskProgressOwnerLease) async
        -> LocalTaskProgressReport {
        let result = await submit(request, priority: .action, lease: lease, fence: nil)
        await finish(lease)
        var ended = await status()
        guard ownerState.isRetired(lease) else { return staleTask() }
        if result.outcome == "refused" { ended.outcome = "refused" }
        ended.reason = result.reason
        ended.update = result.update
        return ended
    }

    private func ownerRequest(_ request: LocalTaskProgressRequest) async -> LocalTaskProgressReport {
        guard let command = request.command, let control = TaskProgressOwnerControl.parse(command) else {
            return .init(outcome: "refused", reason: "invalid_owner_control")
        }
        return await controlled(await applyOwner(control))
    }

    private func applyOwner(_ control: TaskProgressOwnerControl) async -> TaskProgressControlResult {
        guard let task = enrollment, let lease = ownerState.lease(for: task) else { return .noTask }
        let admission = ownerAdmission(control, lease: lease, source: .local)
        return await timer().owner(control, task: task, generation: lease.generation, admission: admission)
    }

    private func controlled(_ result: TaskProgressControlResult) async
        -> LocalTaskProgressReport {
        var report = await status()
        if result != .applied { report.outcome = "refused"; report.reason = String(describing: result) }
        return report
    }

    private func start(_ request: LocalTaskProgressRequest) async -> LocalTaskProgressReport {
        guard enrollment == nil, let reservation = ownerState.reserveStart() else {
            return .init(outcome: "refused", reason: "task_already_active")
        }
        defer { ownerState.cancelStart(reservation) }
        guard let target = request.target, let id = request.task, let listener,
              let listed = try? await host.registry.listing().first(where: { $0.info.id == target }),
              listed.info.alive, let binding = listed.binding else {
            return .init(outcome: "refused", reason: "unknown_target")
        }
        let grant = await host.inputPolicyGeneration(for: target)
        guard grant.wasGranted, grant.binding == binding else {
            return .init(outcome: "refused", reason: "policy_denied")
        }
        let task = TaskProgressTask(id: id, session: target, binding: binding)
        guard let lease = ownerState.enroll(task, reservation: reservation, lifetime: ownerLifetime) else {
            return staleTask()
        }
        let scheduler = timer()
        (enrollment, generation) = (task, grant)
        expires = clock.now().advanced(by: .seconds(6 * 3_600))
        lastText = nil
        outstandingPrivacyRevision = nil
        outstandingOutputFence = nil
        outstandingWake = nil
        let environment = await listener.taskProgressEnvironment(for: target)
        let admission = TaskProgressEnrollmentAdmission(state: ownerState, lease: lease, lifetime: ownerLifetime)
        guard await scheduler.start(task, interval: .seconds(request.seconds ?? 300), generation: lease.generation,
                                    environment: environment, admission: admission) else {
            await finish(lease)
            return .init(outcome: "refused", reason: "invalid_interval")
        }
        // A live availability edge may have arrived while either actor hop above was suspended.
        await refresh(lease)
        guard ownerState.isCurrent(lease) else { return staleTask() }
        let report = await status()
        return ownerState.isCurrent(lease) ? report : staleTask()
    }

    func refresh() async {
        guard let task = enrollment, let lease = tryLease(task) else { return }
        await refresh(lease)
    }

    private func refresh(_ lease: TaskProgressOwnerLease) async {
        guard ownerState.isCurrent(lease), let listener else { return }
        let environment = await listener.taskProgressEnvironment(for: lease.task.session)
        await timer().observe(environment, task: lease.task, generation: lease.generation)
    }

    func owner(_ control: TaskProgressOwnerControl, connection: UUID, stream: UUID) async -> Bool {
        guard let task = enrollment, let lease = ownerState.lease(for: task), let listener else { return false }
        if let before = TaskProgressOwnerControlScope.beforeValidation { await before(task) }
        guard let source = await listener.taskProgressOwnerSource(for: task.session, connection: connection,
                                                                  stream: stream) else { return false }
        let admission = ownerAdmission(control, lease: lease, source: source)
        return await timer().owner(control, task: task, generation: lease.generation, admission: admission) == .applied
    }

    func stop() async {
        ownerState.cancelStart()
        if let task = enrollment, let lease = tryLease(task) { await finish(lease) }
    }

    private func finish(_ lease: TaskProgressOwnerLease) async {
        guard enrollment == lease.task, ownerState.retire(lease) else { return }
        await timer().finish(task: lease.task, generation: lease.generation)
        guard ownerState.isRetired(lease), enrollment == lease.task else { return }
        enrollment = nil
        generation = nil
        expires = nil
        lastText = nil
        outstandingPrivacyRevision = nil
        outstandingOutputFence = nil
        outstandingWake = nil
    }
}

private extension ListenerTaskProgress {
    private func ownerAdmission(_ control: TaskProgressOwnerControl, lease: TaskProgressOwnerLease,
                                source: TaskProgressOwnerSource) -> TaskProgressRetainedOwnerAdmission {
        .init(state: ownerState, lease: lease, lifetime: ownerLifetime, source: source, control: control)
    }

    private func tryLease(_ task: TaskProgressTask) -> TaskProgressOwnerLease? { ownerState.lease(for: task) }
    private func staleTask() -> LocalTaskProgressReport { .init(outcome: "refused", reason: "stale_task") }

    func wake(_ wake: TaskProgressWake) async {
        defer { TaskProgressWakeScope.didFinishWake?() }
        if let before = TaskProgressControllerLifetimeScope.beforeWake { await before(wake) }
        guard enrollment == wake.task, let lease = tryLease(wake.task),
              lease.generation == wake.enrollmentGeneration else { return }
        guard await timer().snapshot().outstanding == wake, ownerState.isCurrent(lease) else { return }
        outstandingWake = wake
        outstandingPrivacyRevision = nil
        outstandingOutputFence = nil
        guard let listener, let generation, let expires, clock.now() < expires else {
            return await finish(wake, lease: lease)
        }
        let lifetime = TaskProgressAdmissionLifetime(expires: expires, clock: clock)
        await refresh(lease)
        guard await timer().permits(wake) else { _ = await timer().complete(wake); return }
        let revision = await listener.taskProgressPrivacyRevision()
        guard ownerState.isCurrent(lease), outstandingWake == wake else { return }
        let fence = outputFence
        outstandingPrivacyRevision = revision
        outstandingOutputFence = fence
        let attempt = TaskProgressWakeAttempt()
        do {
            // The retained generation is never refreshed here. Revoke/restore cannot resurrect this enrollment.
            try generation.requireCurrent()
            guard await timer().permits(wake),
                  await listener.taskProgressConnection(for: wake.task.session) != nil else {
                _ = await timer().complete(wake)
                return
            }
            let context = TaskProgressWakeContext(generation: generation, attempt: attempt, lifetime: lifetime,
                                                  revision: revision, fence: fence)
            let result = try await sendWake(wake, listener: listener, context: context)
            guard case .delivered = result else { return await finish(wake, lease: lease) }
        } catch is CancellationError {
            // Only proven zero-attempt cancellation releases the solicitation. An ambiguous handoff stays busy.
            await cancelWake(wake, lease: lease, attempt: attempt, lifetime: lifetime)
        } catch {
            // Refused/busy/rebound is inspectable stopped state; never a retry or recovery storm.
            await finish(wake, lease: lease)
        }
    }

    private func cancelWake(_ wake: TaskProgressWake, lease: TaskProgressOwnerLease,
                            attempt: TaskProgressWakeAttempt, lifetime: TaskProgressAdmissionLifetime) async {
        guard !attempt.hasAttempt else { return }
        if lifetime.isExpired { await finish(wake, lease: lease) } else { _ = await timer().complete(wake) }
    }

    private func finish(_ wake: TaskProgressWake, lease: TaskProgressOwnerLease) async {
        guard outstandingWake == wake else { return }
        await finish(lease)
    }

    private func sendWake(_ wake: TaskProgressWake, listener: WebSocketListener,
                          context: TaskProgressWakeContext) async throws -> SendOutcome {
        guard await timer().permits(wake) else { throw CancellationError() }
        let authority = TaskProgressPublicationAuthority(generation: context.generation, binding: wake.task.binding,
                                                          taskFence: context.fence)
        guard
              let retained = await listener.taskProgressDeliveryStages(for: wake.task, authority: authority,
                                                              privacyRevision: context.revision,
                                                              attempt: context.attempt,
                                                              lifetime: context.lifetime) else {
            throw CancellationError()
        }
        return try await TaskProgressWakeScope.$retained.withValue(retained) {
            try await host.sendAuthorized(wake.statusPrompt, policyGeneration: context.generation,
                                          from: "task-progress", expectedBinding: wake.task.binding, context: nil)
        }
    }

    private func report(_ request: LocalTaskProgressRequest) async -> LocalTaskProgressReport {
        let scheduler = timer()
        guard let outstanding = await scheduler.snapshot().outstanding, outstanding.task == enrollment,
              request.token == outstanding.token, let lease = tryLease(outstanding.task),
              lease.generation == outstanding.enrollmentGeneration, outstandingWake == outstanding else {
            return .init(outcome: "refused", reason: "stale_update")
        }
        let revision = outstandingPrivacyRevision, fence = outstandingOutputFence
        await refresh(lease)
        guard ownerState.isCurrent(lease) else { return staleTask() }
        let result: LocalTaskProgressReport
        if await scheduler.permits(outstanding), fence?.isOpen == true,
           let expected = revision, let listener,
           await listener.taskProgressPrivacyRevision() == expected {
            result = await SessionUpdatePrivacyScope.$expectedRevision.withValue(expected) {
                await submit(request, priority: .info, lease: lease, fence: fence)
            }
        } else {
            result = .init(outcome: "suppressed", reason: "paused")
        }
        _ = await scheduler.complete(outstanding)
        if let before = TaskProgressControllerLifetimeScope.beforeReportCleanup { await before(outstanding) }
        guard ownerState.isCurrent(lease) else { return staleTask() }
        if outstandingWake == outstanding {
            outstandingPrivacyRevision = nil
            outstandingOutputFence = nil
            outstandingWake = nil
        }
        if result.reason == "retired_authority" || result.update?.reason == "retired_authority" {
            await finish(lease)
        }
        var current = await status()
        guard ownerState.isCurrent(lease) || ownerState.isRetired(lease) else { return staleTask() }
        current.outcome = result.outcome
        current.reason = result.reason
        current.update = result.update
        return current
    }

    private func submit(_ request: LocalTaskProgressRequest, priority: SessionUpdatePriority,
                        lease: TaskProgressOwnerLease, fence: TaskProgressOutputFence?) async
        -> LocalTaskProgressReport {
        guard enrollment == lease.task, ownerState.isCurrent(lease) else { return staleTask() }
        let task = lease.task
        guard let generation, generation.performIfCurrent({ true }) == true else {
            return .init(outcome: "refused", reason: "retired_authority")
        }
        guard let text = request.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return .init(outcome: "unchanged")
        }
        guard text != lastText else { return .init(outcome: "unchanged") }
        guard let listener else { return .init(outcome: "refused", reason: "stopped") }
        let authority = TaskProgressPublicationAuthority(generation: generation, binding: task.binding,
            taskFence: priority == .info ? fence : nil)
        let details = ["Task: `\(task.id.uuidString)`", request.card].compactMap { $0 }
            .joined(separator: "\n\n")
        let update = await TaskProgressPublicationScope.$authority.withValue(authority) {
            await listener.sessionUpdate(.init(action: .submit, target: task.session, priority: priority,
                                               text: text, card: details))
        }
        var result = await status()
        guard ownerState.isCurrent(lease) else { return staleTask() }
        result.update = update
        if update.outcome != .refused && update.outcome != .notEnabled { lastText = text }
        return result
    }

    private func status() async -> LocalTaskProgressReport {
        let snapshot = await timer().snapshot()
        var report = LocalTaskProgressReport(outcome: "status")
        report.task = snapshot.task?.id
        report.session = snapshot.task?.session
        report.intervalSeconds = Int(snapshot.interval.components.seconds)
        report.setBy = snapshot.setByOwner ? "owner" : "agent"
        report.pauseReason = snapshot.pauseReason?.rawValue
        report.nextDueInSeconds = snapshot.nextDue.map { max(0, Int(clock.now().duration(to: $0).components.seconds)) }
        report.outstanding = snapshot.outstanding != nil
        return report
    }
}

extension WebSocketListener {
    func enableTaskProgress(clock: TaskProgressClock = .continuous) {
        guard sessionUpdates.policy.enabled, !stopped, taskProgressController == nil else { return }
        taskProgressController = ListenerTaskProgress(listener: self, host: host, clock: clock,
                                                      ownerLifetime: taskProgressOwnerLifetime)
    }

    public func taskProgress(_ request: LocalTaskProgressRequest) async -> LocalTaskProgressReport {
        guard !stopped, let taskProgressController else {
            return .init(outcome: "not_enabled", reason: "requires_task_progress_and_session_updates")
        }
        return await taskProgressController.handle(request)
    }

    func refreshTaskProgressEnvironment() async { await taskProgressController?.refresh() }

    func taskProgressPrivacyRevision() -> UInt64 { replyHold.entryRevision }

    func taskProgressConnection(for target: String) async -> UUID? {
        guard await sessionUpdatePauseReason(for: target) == nil else { return nil }
        return updateAudience(for: target).target
    }

    /// Owner controls keep their attribution while output is quiet, media-held or rendering.
    /// This checks identity only; it neither releases output policy nor creates a recipient grant.
    func taskProgressControlConnection(for target: String) async -> UUID? {
        guard !stopped, let connection = updateAudience(for: target).target,
              let peer = peers.values.first(where: { $0.session.connectionID == connection }),
              await peer.isLive, await peer.session.canReceiveSessionUpdate(target: target,
                lastInput: lastInput.latest(for: target)) else { return nil }
        return connection
    }

    func taskProgressOwnerSource(for target: String, connection: UUID, stream: UUID) async -> TaskProgressOwnerSource? {
        guard await taskProgressControlConnection(for: target) == connection, !stopped, let ambient else { return nil }
        return .ambient(ambient, TaskProgressAmbientAudience(connection: connection, stream: stream))
    }

    func taskProgressEnvironment(for target: String) async -> TaskProgressEnvironment {
        var environment = TaskProgressEnvironment()
        let reason = await sessionUpdatePauseReason(for: target)
        environment.privateMode = reason == "private"
        environment.quiet = reason == "quiet"
        environment.media = reason == "media"
        environment.ownerSpeaking = reason == "owner_speaking"
        environment.playback = reason == "playback"
        let connection = updateAudience(for: target).target
        environment.connected = connection.map { id in
            peers.values.contains(where: { $0.session.connectionID == id })
        } ?? false
        environment.listening = connection != nil && ambient?.activeConnection() == connection
        // Output readiness and recipient identity are different facts. A known peer remains the intended
        // recipient while rendering or another explicit policy hold applies; an unknown/refused availability
        // result must still fail closed even if a peer happens to remain in the connection table.
        let recipient = await taskProgressControlConnection(for: target)
        switch reason {
        case nil, "private", "quiet", "media", "owner_speaking", "playback":
            environment.uniqueRecipient = recipient != nil
        default: environment.uniqueRecipient = false
        }
        return environment
    }

    func taskProgressOwner(_ control: TaskProgressOwnerControl, connection: UUID, stream: UUID) async -> Bool {
        guard !stopped, ambient?.activeConnection() == connection,
              ambient?.isLatest(stream: stream, connection: connection) == true,
              let taskProgressController else { return false }
        return await taskProgressController.owner(control, connection: connection, stream: stream)
    }
}
