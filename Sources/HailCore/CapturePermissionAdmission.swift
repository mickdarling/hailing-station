/// Acquires capture admission before permission waits. The availability predicate applies before reservation;
/// an owner's reservation must not be mistaken for a competing capture after permission is granted (#266).
@MainActor
public enum CapturePermissionAdmission {
    public static func request(
        mayBegin: () -> Bool, reserve: () -> Void, permissions: () async -> Bool, release: () -> Void
    ) async -> Bool {
        guard !Task.isCancelled, mayBegin() else { return false }
        reserve()
        let granted = await permissions()
        guard granted, !Task.isCancelled else { release(); return false }
        return true // The caller retains admission through startup and joined resource cleanup.
    }
}
