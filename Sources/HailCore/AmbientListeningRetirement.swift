import Foundation

/// One ambient session's work, including startup and paused streams whose cleanup outlives the toggle.
/// Main-actor operations enter before suspending and leave only after their owned cleanup has finished.
@MainActor
final class AmbientListeningRetirement {
    private var pending = 0
    private var completed = false
    private var completion: (@MainActor () -> Void)?
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private(set) var isRetiring = false

    func begin() { pending += 1 }

    func finish() {
        pending -= 1
        guard isRetiring, pending == 0, !completed else { return }
        completed = true
        let completion = completion
        self.completion = nil
        completion?()
        let waiters = waiters
        self.waiters.removeAll()
        waiters.forEach { $0.resume() }
    }

    /// The caller has entered its own cleanup operation before marking this session as retiring.
    func retire(completion: @escaping @MainActor () -> Void) {
        isRetiring = true
        self.completion = completion
    }

    func wait() async {
        guard isRetiring, !completed else { return }
        await withCheckedContinuation { waiters.append($0) }
    }
}
