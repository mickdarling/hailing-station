import HailCore
import SwiftUI

enum ListeningSettingsIntent {
    case setMaskPreference(Bool)
    case manageInStation
}

/// Ambient-owner state only. It cannot establish the capture engine or Talk microphone's state.
struct ListeningSettingsState {
    enum Activity: Equatable {
        case unavailable, off, requested, streaming, paused, reconnecting, movedAway

        var label: String {
            switch self {
            case .unavailable: "Not reported"
            case .off: "Ambient listening off"
            case .requested: "Requested on · not streaming"
            case .streaming: "Streaming room audio"
            case .paused: "Ambient listening paused"
            case .reconnecting: "Reconnecting · delivery unconfirmed"
            case .movedAway: "Listening moved to another device"
            }
        }
    }

    let requestedOn: Bool?
    let activity: Activity
    let detail: String?

    @MainActor
    init(controller: AmbientListeningController?) {
        requestedOn = controller?.isOn
        guard let controller else {
            activity = .unavailable
            detail = "Use Station to review the ambient listening controls."
            return
        }
        if controller.reconnect.isPending {
            activity = .reconnecting
            detail = "Ambient capture may continue while the connection restores. Delivery is not confirmed."
        } else if let reason = controller.pausedReason {
            activity = .paused
            detail = reason
        } else if controller.isListening {
            activity = .streaming
            detail = controller.handoff?.status
        } else if let handoff = controller.handoff, case .movedAway = handoff {
            activity = .movedAway
            detail = handoff.status
        } else {
            activity = controller.isOn ? .requested : .off
            detail = controller.stopReason
        }
    }
}

/// Reads ambient status and emits explicit existing-preference/navigation intents; no audio owner lives here.
struct ListeningSettingsView: View {
    let state: ListeningSettingsState
    let masksDuringReplies: Bool
    let send: (ListeningSettingsIntent) -> Void

    var body: some View {
        Form {
            Section {
                valueRow("Ambient request", value: requestLabel, id: "request")
                valueRow("Reported activity", value: state.activity.label, id: "activity")
                if let detail = state.detail {
                    Text(detail).fixedSize(horizontal: false, vertical: true)
                        .accessibilityIdentifier("settings.listening.detail")
                }
                Button("Manage ambient listening in Station") { send(.manageInStation) }
                    .accessibilityIdentifier("settings.listening.manage")
            } header: {
                Text("This device")
            } footer: {
                Text("This page reports ambient listening only. It does not confirm that every microphone is off.")
            }
            maskSection
            Section("Attention on the Mac") {
                Text("Attention presets, cue rules, speaker thresholds and models cannot be read or edited here.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.listening.attention-unavailable")
            }
        }
        .navigationTitle("Listening and attention")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .accessibilityIdentifier("settings.listening.overview")
    }

    private var requestLabel: String {
        state.requestedOn.map { $0 ? "On" : "Off" } ?? "Not reported"
    }

    private var maskSection: some View {
        Section {
            Toggle("Mask ambient microphone during replies", isOn: Binding(
                get: { masksDuringReplies }, set: { send(.setMaskPreference($0)) }))
                .accessibilityIdentifier("settings.listening.mask-preference")
        } header: {
            Text("Saved preference")
        } footer: {
            Text("Used by Station’s ambient controls to send silence during replies, without turning off the mic. "
                 + "Some headphone routes mask independently. This choice does not confirm current masking.")
        }
    }

    private func valueRow(_ title: String, value: String, id: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Text(value).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("settings.listening.\(id)")
    }
}
