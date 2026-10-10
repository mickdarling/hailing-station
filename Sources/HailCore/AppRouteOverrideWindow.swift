import Synchronization

/// The route switches the app makes on its own (#459). `selectPreferredInput` opens a short window around each switch,
/// and an `override` route change inside it is the app restoring the preferred input, not the user changing hardware.
/// Ambient capture keeps running through it unless the engine actually stopped.
public final class AppRouteOverrideWindow: Sendable {
    public static let shared = AppRouteOverrideWindow()
    static let duration: Duration = .seconds(1)
    private let until = Mutex<ContinuousClock.Instant?>(nil)
    private let now: @Sendable () -> ContinuousClock.Instant

    init(now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }) { self.now = now }

    func open() {
        let deadline = now() + Self.duration
        until.withLock { $0 = deadline }
    }

    var isOpen: Bool {
        let instant = now()
        return until.withLock { deadline in deadline.map { instant < $0 } ?? false }
    }
}
