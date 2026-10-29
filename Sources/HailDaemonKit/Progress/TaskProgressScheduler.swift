public import Foundation

/// Event-driven deadline owner for one explicitly enrolled task (#1013). The callback is a request for status,
/// not permission to submit provider input: composition must check live target policy, binding and task authority.
/// A callback must not renew a voice request, interrupt a provider or recover a stalled session (#720, #1002).
public actor TaskProgressScheduler {
    public typealias Wake = @Sendable (TaskProgressWake) async -> Void
    private var state = TaskProgressState()
    private let clock: TaskProgressClock
    private let wake: Wake
    private var deadline: Task<Void, Never>?
    private var dispatch: Task<Void, Never>?
    private var revision: UInt64 = 0

    public init(clock: TaskProgressClock = .continuous, wake: @escaping Wake) {
        (self.clock, self.wake) = (clock, wake)
    }

    deinit {
        deadline?.cancel()
        dispatch?.cancel()
    }

    public func snapshot() -> TaskProgressSnapshot { state.snapshot }
    public func permits(_ wake: TaskProgressWake) -> Bool { state.permits(wake) }

    @discardableResult
    public func start(_ task: TaskProgressTask, interval: Duration = .seconds(300)) -> Bool {
        guard state.start(task, interval: interval, at: clock.now()) else { return false }
        dispatch?.cancel()
        dispatch = nil
        reschedule()
        return true
    }

    public func finish(task id: UUID) {
        guard state.task?.id == id else { return }
        state.finish(task: id)
        dispatch?.cancel()
        dispatch = nil
        reschedule()
    }

    @discardableResult
    public func owner(_ control: TaskProgressOwnerControl) -> TaskProgressControlResult {
        let result = state.owner(control, at: clock.now())
        if result == .applied {
            switch control {
            case .pause, .stop: dispatch?.cancel()
            default: break
            }
            reschedule()
        }
        return result
    }

    @discardableResult
    public func agent(interval: Duration) -> TaskProgressControlResult {
        let result = state.agent(interval: interval, at: clock.now())
        if result == .applied { reschedule() }
        return result
    }

    public func observe(_ environment: TaskProgressEnvironment) {
        state.observe(environment, at: clock.now())
        if environment.pauseReason != nil { dispatch?.cancel() }
        reschedule()
    }

    @discardableResult
    public func complete(_ wake: TaskProgressWake) -> Bool {
        guard state.complete(wake, at: clock.now()) else { return false }
        dispatch = nil
        reschedule()
        return true
    }

    private func reschedule() {
        revision &+= 1
        deadline?.cancel()
        deadline = nil
        guard let due = state.nextDue else { return }
        let revision = revision
        let clock = clock
        deadline = Task { [weak self] in
            do { try await clock.sleepUntil(due) } catch { return }
            guard !Task.isCancelled else { return }
            await self?.elapsed(revision: revision)
        }
    }

    private func elapsed(revision expected: UInt64) {
        guard revision == expected, let update = state.due(at: clock.now()) else { return }
        deadline = nil
        let wake = wake
        dispatch = Task {
            guard !Task.isCancelled else { return }
            await wake(update)
        }
    }
}
