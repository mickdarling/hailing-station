import HailCore
import SwiftUI

extension StationAvailability {
    var isWorking: Bool {
        switch self {
        case .connecting, .reconnecting, .waitingForTargets, .restoringSelection: true
        default: false
        }
    }

    var canChooseDestination: Bool {
        self == .chooseTarget || self == .selectionFailed
    }

    var emptyTitle: String {
        switch self {
        case .unconfigured: "Connect Haley to a Mac"
        case .connecting: "Connecting to Mac"
        case .reconnecting: "Reconnecting to Mac"
        case .waitingForTargets: "Checking destinations"
        case .restoringSelection: "Restoring destination"
        case .chooseTarget: "Choose a destination"
        case .noAllowedTargets: "No available destinations"
        case .selectionFailed: "Destination needs attention"
        case .ready: "Ready"
        case .failed: "Mac connection needs attention"
        case .offline: "Mac is offline"
        }
    }

    var emptyDetail: String {
        switch self {
        case .unconfigured:
            "Add a Mac, connect it, then choose the destination Haley should use."
        case .connecting:
            "Opening the Mac connection. You can check its details in Mac Setup."
        case .reconnecting:
            "The connection was interrupted. Haley is trying again; check Mac Setup if it does not recover."
        case .waitingForTargets:
            "The Mac connection is open, but its allowed destinations have not arrived yet."
        case .restoringSelection:
            "Confirming your remembered destination on this connection before talk is available."
        case .chooseTarget:
            "Your Mac is connected. Choose the allowed destination Haley should use."
        case .noAllowedTargets:
            "The Mac is connected but has no live destination you are allowed to use. Check the host and its policy."
        case .selectionFailed:
            "The remembered destination was not confirmed on this connection. Choose a live destination again."
        case .ready:
            "The selected destination is confirmed on this connection."
        case .failed:
            "The Mac connection failed. Open Mac Setup to see the reason and retry."
        case .offline:
            "The Mac is not connected. Open Mac Setup to reconnect."
        }
    }

    var badge: StationConnectionPresentation {
        switch self {
        case .ready:
            StationConnectionPresentation(label: "Ready", systemImage: "checkmark.circle.fill", color: .green)
        case .chooseTarget:
            StationConnectionPresentation(label: "Choose a target", systemImage: "scope", color: .blue)
        case .connecting:
            StationConnectionPresentation(
                label: "Connecting", systemImage: "arrow.trianglehead.2.clockwise", color: .orange
            )
        case .reconnecting:
            StationConnectionPresentation(
                label: "Reconnecting", systemImage: "arrow.trianglehead.2.clockwise", color: .orange
            )
        case .waitingForTargets:
            StationConnectionPresentation(label: "Checking targets", systemImage: "ellipsis.circle", color: .orange)
        case .restoringSelection:
            StationConnectionPresentation(label: "Restoring target", systemImage: "ellipsis.circle", color: .orange)
        case .noAllowedTargets:
            StationConnectionPresentation(label: "No targets", systemImage: "scope", color: .red)
        case .selectionFailed:
            StationConnectionPresentation(
                label: "Target unavailable", systemImage: "exclamationmark.triangle.fill", color: .red
            )
        case .failed:
            StationConnectionPresentation(
                label: "Needs attention", systemImage: "exclamationmark.triangle.fill", color: .red
            )
        case .offline:
            StationConnectionPresentation(label: "Offline", systemImage: "circle.dashed", color: .secondary)
        case .unconfigured:
            StationConnectionPresentation(label: "No Mac configured", systemImage: "circle.dashed", color: .secondary)
        }
    }
}
