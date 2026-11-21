import Observation
import SwiftUI
import UserNotifications

/// The settings callback's objects stay on its executor; only a Sendable status reaches the UI owner.
enum SystemNotificationAccessReader {
    static func read() async -> NotificationAccessStatus {
        await withCheckedContinuation { continuation in
            UNUserNotificationCenter.current().getNotificationSettings { settings in
                continuation.resume(returning: Self.map(settings.authorizationStatus))
            }
        }
    }

    static func map(_ status: UNAuthorizationStatus) -> NotificationAccessStatus {
        switch status {
        case .notDetermined: .notDetermined
        case .denied: .denied
        case .authorized: .authorized
        case .provisional: .provisional
        #if os(iOS)
        case .ephemeral: .ephemeral
        #endif
        @unknown default: .unknown(status.rawValue)
        }
    }
}

/// One last-check snapshot per station window. Construction, observation and disappearance never read the OS.
@MainActor @Observable
final class NotificationAccessModel {
    private let read: @Sendable () async -> NotificationAccessStatus
    private(set) var status: NotificationAccessStatus?
    private(set) var isChecking = false

    init(read: @escaping @Sendable () async -> NotificationAccessStatus = {
        await SystemNotificationAccessReader.read()
    }) {
        self.read = read
    }

    /// Exactly one query at a time. The returned task permits deterministic qualification without timers.
    @discardableResult
    func check() -> Task<Void, Never>? {
        guard !isChecking else { return nil }
        isChecking = true
        let read = self.read
        return Task { [weak self] in
            guard !Task.isCancelled else {
                self?.isChecking = false
                return
            }
            let result = await read()
            guard let self else { return }
            if !Task.isCancelled { self.status = result }
            self.isChecking = false
        }
    }
}

extension StationRootView {
    var notificationSettingsOverview: some View {
        NotificationsSettingsOverview(model: station.value.notificationAccess)
    }
}
