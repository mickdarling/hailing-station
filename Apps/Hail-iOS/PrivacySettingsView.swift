import HailCore
import SwiftUI

enum PrivacySettingsIntent: Equatable {
    case privacy(Bool, host: HostEndpoint.Identifier, generation: UUID)
    case showOverheard(Bool)
    case whoseOverheard(String)
    case stopListening
}

struct PrivacySettingsRequestState {
    var id = UUID()
    var failure: String?
    var overheardFailure: String?
}

struct PrivacySettingsState {
    let host: HostConnectionSnapshot?
    let privacy: PrivacySwitchStatus
    let isListeningToHost: Bool
    let unavailableReason: String?
    let canStopListening: Bool
    let showOverheard: Bool
    let whoseOverheard: String
    let requestedScope: String
    let failure: String?
    let overheardFailure: String?

    var knowsWhose: Bool { ["owner", "everyone"].contains(whoseOverheard) }
    var canRequestPrivacy: Bool { unavailableReason == nil }
    var privacyDetail: String {
        guard !isListeningToHost else { return privacy.detail }
        switch privacy.shown {
        case .confirmedPrivate:
            return "The Mac confirmed privacy on. Ambient audio is not currently streaming to this Mac."
        case .confirmedNotPrivate:
            return "The Mac confirmed privacy off. Ambient audio is not currently streaming to this Mac."
        case .privateListeningUnavailable, .unconfirmed: return privacy.detail
        }
    }
    var connection: String {
        guard let host else { return "No Mac selected" }
        switch host.state {
        case .ready: return "Connected"
        case .connecting, .negotiating: return "Connecting"
        case .reconnecting: return "Reconnecting"
        case .failed: return "Connection failed"
        case .disconnected: return "Offline"
        }
    }
    var requestedScopeDescription: String {
        switch requestedScope {
        case "off": "Off"
        case "owner": "Just me"
        case "everyone": "Everyone"
        default: "Not confirmed"
        }
    }
}

/// Immutable observations and explicit owner intents. Opening or leaving performs no request or preference write.
struct PrivacySettingsView: View {
    let state: PrivacySettingsState
    let send: @MainActor (PrivacySettingsIntent) -> Void

    var body: some View {
        Form {
            Section("Selected Mac · this device's stream") {
                LabeledContent("Mac", value: state.host?.endpoint.name ?? "None selected")
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("settings.privacy.host")
                LabeledContent("Connection", value: state.connection)
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("settings.privacy.connection")
                privacyControl
                Text(state.privacyDetail).font(.footnote).foregroundStyle(.secondary)
                    .accessibilityIdentifier("settings.privacy.status-detail")
                if let reason = state.unavailableReason {
                    Text(reason).font(.footnote).foregroundStyle(.secondary)
                        .accessibilityIdentifier("settings.privacy.unavailable")
                }
            }
            Section {
                Button("Stop listening", role: .destructive) { send(.stopListening) }
                    .disabled(!state.canStopListening)
                    .accessibilityIdentifier("settings.privacy.stop-listening")
            } header: {
                Text("This device")
            } footer: {
                Text("Privacy does not turn the microphone off. Stop listening ends ambient listening on this device.")
            }
            overheardSection
            if let failure = state.failure {
                Section("Privacy request not completed") {
                    Text(failure).accessibilityIdentifier("settings.privacy.failure")
                }
            }
            Section("Host policy") {
                Text("Meeting, recording and retention policies are not available here.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle("Privacy")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.privacy.page")
    }

    private var privacyControl: some View {
        Toggle(isOn: Binding(get: { state.privacy.isPrivate }, set: { on in
            guard let host = state.host else { return }
            send(.privacy(on, host: host.id, generation: host.connectionGeneration))
        })) {
            Text(state.privacy.title).fixedSize(horizontal: false, vertical: true)
        }
        .disabled(!state.canRequestPrivacy)
        .accessibilityLabel("Privacy")
        .accessibilityValue(state.privacy.title)
        .accessibilityHint("Shows private only after the Mac confirms.")
        .accessibilityIdentifier("settings.privacy.switch")
    }

    private var overheardSection: some View {
        Section {
            Toggle("Show overheard remarks", isOn: Binding(
                get: { state.showOverheard }, set: { send(.showOverheard($0)) }))
                .disabled(!state.knowsWhose && !state.showOverheard)
                .accessibilityIdentifier("settings.privacy.overheard-show")
            Picker("Whose remarks", selection: Binding(
                get: { state.whoseOverheard }, set: { send(.whoseOverheard($0)) })) {
                if !state.knowsWhose { Text("Not recognized").tag(state.whoseOverheard) }
                Text("Just me").tag("owner")
                Text("Everyone").tag("everyone")
            }
            .accessibilityIdentifier("settings.privacy.overheard-whose")
            LabeledContent("Current request scope", value: state.requestedScopeDescription)
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("settings.privacy.overheard-requested")
            if let failure = state.overheardFailure {
                Text(failure).accessibilityIdentifier("settings.privacy.overheard-failure")
            }
        } header: {
            Text("This device · overheard remarks")
        } footer: {
            Text("Shows speech heard but not sent as a request. The saved choice applies to every ready Mac that "
                 + "supports overheard remarks; the requested scope is not delivery confirmation.")
        }
    }
}
