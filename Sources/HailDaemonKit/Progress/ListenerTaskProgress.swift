import Foundation

// Enrollment, deadline commits and listener wiring share the same private state owner.
// swiftlint:disable file_length

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
    private var outputFence = TaskProgressOutputFence()
    private var outstandingOutputFence: TaskProgressOutputFence?
    private var handling = false

    init(listener: WebSocketListener, host: HailHost, clock: TaskProgressClock = .continuous) {
        (self.listener, self.host, self.clock) = (listener, host, clock)
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
        guard let task = enrollment, request.task == task.id else {
            return .init(outcome: "refused", reason: "no_matching_task")
        }
        let scheduler = timer()
        switch request.action {
        case .start, .status: return .init(outcome: "refused", reason: "invalid")
        case .interval:
            return await controlled(await scheduler.agent(interval: .seconds(request.seconds ?? 0)))
        case .owner: return await ownerRequest(request)
        case .cancel:
            await finish(task.id)
            return await status()
        case .finish: return await finishRequest(request, task: task)
        case .report: return await report(request)
        }
    }

    private func finishRequest(_ request: LocalTaskProgressRequest, task: TaskProgressTask) async
        -> LocalTaskProgressReport {
        let result = await submit(request, priority: .action)
        await finish(task.id)
        var ended = await status()
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
        switch control {
        case .pause, .stop: outputFence.close()
        case .resume: outputFence = TaskProgressOutputFence()
        default: break
        }
        return await timer().owner(control)
    }

    private func controlled(_ result: TaskProgressControlResult) async
        -> LocalTaskProgressReport {
        var report = await status()
        if result != .applied { report.outcome = "refused"; report.reason = String(describing: result) }
        return report
    }

    private func start(_ request: LocalTaskProgressRequest) async -> LocalTaskProgressReport {
        guard enrollment == nil else { return .init(outcome: "refused", reason: "task_already_active") }
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
        let scheduler = timer()
        (enrollment, generation) = (task, grant)
        expires = clock.now().advanced(by: .seconds(6 * 3_600))
        lastText = nil
        outstandingPrivacyRevision = nil
        outputFence = TaskProgressOutputFence()
        outstandingOutputFence = nil
        await scheduler.observe(await listener.taskProgressEnvironment(for: target))
        guard await scheduler.start(task, interval: .seconds(request.seconds ?? 300)) else {
            await finish(task.id)
            return .init(outcome: "refused", reason: "invalid_interval")
        }
        // A live availability edge may have arrived while either actor hop above was suspended.
        await refresh()
        return await status()
    }

    func refresh() async {
        guard let task = enrollment, let listener else { return }
        await timer().observe(await listener.taskProgressEnvironment(for: task.session))
    }

    func owner(_ control: TaskProgressOwnerControl, connection: UUID) async -> Bool {
        guard let task = enrollment, let listener,
              await listener.taskProgressControlConnection(for: task.session) == connection else { return false }
        return await applyOwner(control) == .applied
    }

    func stop() async { if let task = enrollment { await finish(task.id) } }

    private func finish(_ id: UUID) async {
        guard enrollment?.id == id else { return }
        outputFence.close()
        await timer().finish(task: id)
        guard enrollment?.id == id else { return }
        enrollment = nil
        generation = nil
        expires = nil
        lastText = nil
        outstandingPrivacyRevision = nil
        outstandingOutputFence = nil
    }
}

private extension ListenerTaskProgress {
    func wake(_ wake: TaskProgressWake) async {
        defer { TaskProgressWakeScope.didFinishWake?() }
        guard enrollment == wake.task, let listener, let generation, let expires, clock.now() < expires else {
            return await finish(wake.task.id)
        }
        let lifetime = TaskProgressAdmissionLifetime(expires: expires, clock: clock)
        await refresh()
        guard await timer().permits(wake) else { _ = await timer().complete(wake); return }
        outstandingPrivacyRevision = await listener.taskProgressPrivacyRevision()
        outstandingOutputFence = outputFence
        let attempt = TaskProgressWakeAttempt()
        do {
            // The retained generation is never refreshed here. Revoke/restore cannot resurrect this enrollment.
            try generation.requireCurrent()
            guard await timer().permits(wake),
                  await listener.taskProgressConnection(for: wake.task.session) != nil else {
                _ = await timer().complete(wake)
                return
            }
            let result = try await sendWake(wake, listener: listener, generation: generation,
                                            attempt: attempt, lifetime: lifetime)
            guard case .delivered = result else { return await finish(wake.task.id) }
        } catch is CancellationError {
            // Only proven zero-attempt cancellation releases the solicitation. An ambiguous handoff stays busy.
            if !attempt.hasAttempt {
                if lifetime.isExpired { await finish(wake.task.id) } else { _ = await timer().complete(wake) }
            }
        } catch {
            // Refused/busy/rebound is inspectable stopped state; never a retry or recovery storm.
            await finish(wake.task.id)
        }
    }

    private func sendWake(
        _ wake: TaskProgressWake, listener: WebSocketListener,
        generation: TargetPolicyGeneration, attempt: TaskProgressWakeAttempt,
        lifetime: TaskProgressAdmissionLifetime
    ) async throws -> SendOutcome {
        guard let revision = outstandingPrivacyRevision, let taskFence = outstandingOutputFence,
              await timer().permits(wake) else { throw CancellationError() }
        let authority = TaskProgressPublicationAuthority(generation: generation, binding: wake.task.binding,
                                                          taskFence: taskFence)
        guard
              let commit = await listener.taskProgressHandoff(for: wake.task, authority: authority,
                                                              privacyRevision: revision, attempt: attempt,
                                                              lifetime: lifetime) else {
            throw CancellationError()
        }
        return try await TaskProgressWakeScope.$beforeHandoff.withValue(commit) {
            try await host.sendAuthorized(wake.statusPrompt, policyGeneration: generation,
                                          from: "task-progress", expectedBinding: wake.task.binding, context: nil)
        }
    }

    private func report(_ request: LocalTaskProgressRequest) async -> LocalTaskProgressReport {
        let scheduler = timer()
        guard let outstanding = await scheduler.snapshot().outstanding, outstanding.task == enrollment,
              request.token == outstanding.token else { return .init(outcome: "refused", reason: "stale_update") }
        await refresh()
        let result: LocalTaskProgressReport
        if await scheduler.permits(outstanding), outstandingOutputFence?.isOpen == true,
           let expected = outstandingPrivacyRevision, let listener,
           await listener.taskProgressPrivacyRevision() == expected {
            result = await SessionUpdatePrivacyScope.$expectedRevision.withValue(expected) {
                await submit(request, priority: .info)
            }
        } else {
            result = .init(outcome: "suppressed", reason: "paused")
        }
        _ = await scheduler.complete(outstanding)
        outstandingPrivacyRevision = nil
        outstandingOutputFence = nil
        if result.reason == "retired_authority" || result.update?.reason == "retired_authority" {
            await finish(outstanding.task.id)
        }
        var current = await status()
        current.outcome = result.outcome
        current.reason = result.reason
        current.update = result.update
        return current
    }

    private func submit(_ request: LocalTaskProgressRequest, priority: SessionUpdatePriority) async
        -> LocalTaskProgressReport {
        guard let task = enrollment else { return .init(outcome: "refused", reason: "no_task") }
        guard let generation, generation.performIfCurrent({ true }) == true else {
            return .init(outcome: "refused", reason: "retired_authority")
        }
        guard let text = request.text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty else {
            return .init(outcome: "unchanged")
        }
        guard text != lastText else { return .init(outcome: "unchanged") }
        guard let listener else { return .init(outcome: "refused", reason: "stopped") }
        let authority = TaskProgressPublicationAuthority(generation: generation, binding: task.binding,
            taskFence: priority == .info ? outstandingOutputFence : nil)
        let details = ["Task: `\(task.id.uuidString)`", request.card].compactMap { $0 }
            .joined(separator: "\n\n")
        let update = await TaskProgressPublicationScope.$authority.withValue(authority) {
            await listener.sessionUpdate(.init(action: .submit, target: task.session, priority: priority,
                                               text: text, card: details))
        }
        var result = await status()
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
        taskProgressController = ListenerTaskProgress(listener: self, host: host, clock: clock)
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
        return await taskProgressController.owner(control, connection: connection)
    }
}
