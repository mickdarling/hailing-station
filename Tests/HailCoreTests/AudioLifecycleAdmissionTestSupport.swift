import Testing
@testable import HailCore

struct AudioLifecycleAdmissionSnapshot: Sendable, Equatable {
    let generation: UInt64
    let wantsActive: Bool
    let waiters: Int
}

extension ManagedAudioSession {
    // One actor turn: task construction is not acknowledgement of lifecycle intent admission.
    func lifecycleAdmissionSnapshot() -> AudioLifecycleAdmissionSnapshot {
        AudioLifecycleAdmissionSnapshot(generation: lifecycleGeneration, wantsActive: wantsActive,
                                        waiters: lifecycleTransitionWaiters.count)
    }
}

enum AudioLifecycleAdmissionTestError: Error {
    case watchdogExpired
}

func waitForAudioTestState(
    timeout: Duration = .seconds(2), predicate: @escaping @Sendable () async -> Bool
) async throws {
    let deadline = ContinuousClock.now.advanced(by: timeout)
    while true {
        try Task.checkCancellation()
        if await predicate() { return }
        guard ContinuousClock.now < deadline else { throw AudioLifecycleAdmissionTestError.watchdogExpired }
        await Task.yield()
    }
}

func acknowledgeAudioLifecycleAdmission(
    _ controller: ManagedAudioSession, generation: UInt64, wantsActive: Bool, waiters: Int,
    timeout: Duration = .seconds(2)
) async throws {
    let expected = AudioLifecycleAdmissionSnapshot(generation: generation, wantsActive: wantsActive, waiters: waiters)
    try await waitForAudioTestState(timeout: timeout) {
        await controller.lifecycleAdmissionSnapshot() == expected
    }
}

// Every launched operation is retained before admission checks. Error cleanup releases both possible
// backend gates and drains all operations, including a task that had not entered the controller yet.
struct AudioLifecycleTestWork {
    let backend: FakeAudioSessionBackend
    private var activations: [Task<Void, any Error>] = []
    private var deactivations: [Task<Void, Never>] = []

    init(backend: FakeAudioSessionBackend) { self.backend = backend }

    mutating func activate(_ controller: ManagedAudioSession) -> Task<Void, any Error> {
        let task = Task { try await controller.activate() }
        activations.append(task)
        return task
    }

    mutating func deactivate(_ controller: ManagedAudioSession) -> Task<Void, Never> {
        let task = Task { await controller.deactivate() }
        deactivations.append(task)
        return task
    }

    func releaseAndDrain() async {
        await backend.releaseHeldConfiguration()
        await backend.releaseHeldActivation()
        for task in activations { _ = try? await task.value }
        for task in deactivations { await task.value }
    }
}
