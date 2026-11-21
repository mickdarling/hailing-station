import Testing

/// An explicit, held data read. It never instantiates UNUserNotificationCenter or touches OS access settings.
actor NotificationAccessReaderSpy {
    private(set) var calls = 0
    private var pending: [Int: CheckedContinuation<NotificationAccessStatus, Never>] = [:]

    func read() async -> NotificationAccessStatus {
        calls += 1
        let request = calls
        return await withCheckedContinuation { pending[request] = $0 }
    }

    func finish(_ request: Int, with status: NotificationAccessStatus) throws {
        let removed = pending.removeValue(forKey: request)
        let continuation = try #require(removed, "An explicit read must be pending")
        continuation.resume(returning: status)
    }
}
