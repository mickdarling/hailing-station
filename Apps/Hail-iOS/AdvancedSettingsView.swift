import HailCore
import SwiftUI

enum AdvancedSettingsIntent: Equatable {
    case setDiagnosticsEnabled(Bool)
}

/// Local diagnostic state and existing tools, with no controller or preference owner of its own (#1115).
struct AdvancedSettingsView<Tools: View>: View {
    let diagnosticsEnabled: Bool
    let bufferedEvents: Int
    let collectingHostName: String?
    let buildInfo: StationBuildInfo
    let send: (AdvancedSettingsIntent) -> Void
    @ViewBuilder let tools: () -> Tools

    var body: some View {
        Form {
            diagnosticsSection
            Section {
                tools()
            } header: {
                Text("Existing tools")
            } footer: {
                Text("Labs includes the redesign switches, which apply after relaunch. "
                     + "Turn-taking edits the existing reply pause and sound-level settings.")
            }
            Section("This app") {
                Text(buildInfo.label)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.advanced.build")
            }
            Section("Host settings") {
                Text("Host configuration, model management and import or export are not available here.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.advanced.host-unavailable")
            }
        }
        .navigationTitle("Advanced and diagnostics")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .accessibilityIdentifier("settings.advanced.overview")
    }

    private var diagnosticsSection: some View {
        Section {
            Toggle("Diagnostics logging", isOn: Binding(
                get: { diagnosticsEnabled }, set: { send(.setDiagnosticsEnabled($0)) }))
                .accessibilityIdentifier("settings.advanced.diagnostics-toggle")
            Text(diagnosticsStatus)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityIdentifier("settings.advanced.diagnostics-status")
            LabeledContent("Buffered events", value: String(bufferedEvents))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("settings.advanced.buffered-events")
        } header: {
            Text("This device")
        } footer: {
            Text("Bounded events about this app, connections and audio; never audio, transcripts or reply contents. "
                 + "Turning logging off clears this device’s buffer. It does not delete events already sent to a Mac.")
        }
    }

    private var diagnosticsStatus: String {
        guard diagnosticsEnabled else { return "Off. No diagnostic events are recorded or sent." }
        guard let collectingHostName else {
            return "On. No connected Mac is collecting diagnostics. Recent events are kept in memory on this device."
        }
        return "On. \(collectingHostName) is ready to collect diagnostics. "
            + "This does not confirm delivery of each event."
    }
}
