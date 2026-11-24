import SwiftUI

enum NotificationAccessStatus: Equatable, Sendable {
    case notDetermined, denied, authorized, provisional, ephemeral
    case unknown(Int)

    var title: String {
        switch self {
        case .notDetermined: "Not determined"
        case .denied: "Denied"
        case .authorized: "Authorized"
        case .provisional: "Provisional"
        case .ephemeral: "Temporary access"
        case .unknown: "Unknown system status"
        }
    }

    var detail: String {
        switch self {
        case .notDetermined: "No notification choice has been reported for this app."
        case .denied: "System notification access is off for this app."
        case .authorized: "System notification access is allowed for this app."
        case .provisional: "Quiet notifications are allowed without full alert authorization."
        case .ephemeral: "The system reports temporary App Clip notification access."
        case .unknown: "The system reported a status this app does not recognize."
        }
    }
}

enum NotificationsSettingsIntent { case checkAccess }

struct NotificationsSettingsView: View {
    let status: NotificationAccessStatus?
    let isChecking: Bool
    let send: @MainActor (NotificationsSettingsIntent) -> Void

    var body: some View {
        Form {
            Section {
                Text(status?.title ?? "Not checked")
                    .accessibilityIdentifier("settings.notifications.access-status")
                Text(status?.detail ?? "Tap Check access to read the system setting.")
                    .font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings.notifications.access-detail")
                Button("Check access") { send(.checkAccess) }
                    .disabled(isChecking)
                    .accessibilityIdentifier("settings.notifications.check")
                if isChecking {
                    ProgressView("Checking access…")
                        .accessibilityIdentifier("settings.notifications.checking")
                }
            } header: {
                Text("This app · last checked system access")
            } footer: {
                Text("Reads access only, without asking for permission. Access does not prove an alert was delivered.")
            }
            Section("Mac-managed updates") {
                Text("Host update cadence and source settings are configured on the Mac host, not on this page.")
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.notifications.host-managed")
                Text("Spoken updates and system notifications use different paths.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Notifications and updates")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.notifications.page")
    }
}

@MainActor
struct NotificationsSettingsOverview: View {
    let model: NotificationAccessModel

    var body: some View {
        NotificationsSettingsView(status: model.status, isChecking: model.isChecking, send: { apply($0) })
    }

    func apply(_ intent: NotificationsSettingsIntent) {
        switch intent {
        case .checkAccess: _ = model.check()
        }
    }
}
