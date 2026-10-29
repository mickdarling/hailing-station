public import Foundation

/// Pure task cadence decisions. All time is supplied by the caller; no I/O or provider authority lives here.
public struct TaskProgressState: Sendable {
    public static let minimumInterval: Duration = .seconds(15)
    public static let maximumInterval: Duration = .seconds(3_600)
    public private(set) var task: TaskProgressTask?
    public private(set) var environment = TaskProgressEnvironment()
    public private(set) var outstanding: TaskProgressWake?
    public private(set) var nextDue: ContinuousClock.Instant?
    private var agentInterval: Duration = .seconds(300)
    private var ownerInterval: Duration?
    private var ownerPause: TaskProgressPauseReason?

    public init() {}

    public var snapshot: TaskProgressSnapshot {
        .init(task: task, interval: interval, setByOwner: ownerInterval != nil,
              pauseReason: task == nil ? nil : pauseReason, nextDue: nextDue, outstanding: outstanding)
    }

    private var interval: Duration { ownerInterval ?? agentInterval }
    private var pauseReason: TaskProgressPauseReason? {
        ownerPause ?? environment.pauseReason ?? (outstanding == nil ? nil : .outstanding)
    }

    /// A replacement retires all old timer/update tokens. Enrollment is an explicit host operation.
    @discardableResult
    public mutating func start(
        _ task: TaskProgressTask, interval: Duration = .seconds(300), at now: ContinuousClock.Instant
    ) -> Bool {
        guard Self.valid(interval), !task.session.isEmpty, !task.binding.isEmpty else { return false }
        self.task = task
        agentInterval = interval
        ownerInterval = nil
        ownerPause = nil
        outstanding = nil
        rebase(at: now)
        return true
    }

    public mutating func finish(task id: UUID) {
        guard task?.id == id else { return }
        task = nil
        nextDue = nil
        outstanding = nil
        ownerPause = nil
        ownerInterval = nil
    }

    /// Owner voice and local agent controls enter this same state; agent settings cannot clear owner choices.
    @discardableResult
    public mutating func owner(
        _ control: TaskProgressOwnerControl, at now: ContinuousClock.Instant
    ) -> TaskProgressControlResult {
        guard task != nil else { return .noTask }
        switch control {
        case .interval(let value):
            guard Self.valid(value) else { return .invalidInterval }
            ownerInterval = value
        case .moreOften: ownerInterval = max(Self.minimumInterval, interval / 2)
        case .lessOften: ownerInterval = min(Self.maximumInterval, interval * 2)
        case .pause: ownerPause = .ownerPaused
        case .stop: ownerPause = .ownerStopped
        case .resume: ownerPause = nil
        }
        rebase(at: now)
        return .applied
    }

    @discardableResult
    public mutating func agent(interval value: Duration, at now: ContinuousClock.Instant)
        -> TaskProgressControlResult {
        guard task != nil else { return .noTask }
        guard Self.valid(value) else { return .invalidInterval }
        guard ownerInterval == nil else { return .ownerControlled }
        agentInterval = value
        rebase(at: now)
        return .applied
    }

    /// A pause forgets its due time. Resuming waits a whole interval; missed ticks never accumulate.
    public mutating func observe(_ value: TaskProgressEnvironment, at now: ContinuousClock.Instant) {
        let previous = pauseReason
        environment = value
        if previous != pauseReason { rebase(at: now) }
    }

    public mutating func due(at now: ContinuousClock.Instant) -> TaskProgressWake? {
        guard let task, pauseReason == nil, let nextDue, now >= nextDue else { return nil }
        let wake = TaskProgressWake(task: task, token: UUID())
        outstanding = wake
        self.nextDue = nil
        return wake
    }

    /// Receipt of a response (including unchanged/unavailable) releases only its exact outstanding token.
    /// It schedules from receipt, not the original deadline, so a busy session cannot create a burst.
    @discardableResult
    public mutating func complete(_ wake: TaskProgressWake, at now: ContinuousClock.Instant) -> Bool {
        guard outstanding == wake, task == wake.task else { return false }
        outstanding = nil
        rebase(at: now)
        return true
    }

    /// Delivery must also recheck the owning host's live binding/authorization at its commit boundary.
    public func permits(_ wake: TaskProgressWake) -> Bool {
        task == wake.task && outstanding == wake && ownerPause == nil && environment.pauseReason == nil
    }

    private mutating func rebase(at now: ContinuousClock.Instant) {
        nextDue = task != nil && pauseReason == nil ? now.advanced(by: interval) : nil
    }

    private static func valid(_ interval: Duration) -> Bool {
        interval >= minimumInterval && interval <= maximumInterval
    }
}
