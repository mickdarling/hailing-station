import HailCore
import SwiftUI

/// A reading of the existing audio owner's state, with no route or session actions of its own (#1115).
struct AudioSettingsOverviewView<Tools: View>: View {
    let state: AudioRoutesSheetState
    let preferredInput: AudioPort?
    let sessionStatus: String
    @ViewBuilder let tools: () -> Tools

    var body: some View {
        Form {
            Section {
                valueRow("Active microphone", value: state.activeInput, identifier: "input")
                valueRow("Preferred microphone", value: preferredDescription, identifier: "preferred")
                valueRow("Observed output", value: state.output, identifier: "output")
            } header: {
                Text("This device")
            } footer: {
                Text("The saved preference can differ from the active microphone. "
                     + "System output means no specific speaker is confirmed.")
            }

            Section("Status") {
                valueRow("Audio state", value: state.status, identifier: "state")
                if sessionStatus != state.status {
                    valueRow("Session update", value: sessionStatus, identifier: "session-update")
                }
                if let failure = state.failure {
                    valueRow("Needs attention", value: failure, identifier: "failure")
                }
            }

            Section {
                NavigationLink { tools() } label: {
                    Label("Audio session tools", systemImage: "waveform")
                }
                .accessibilityIdentifier("settings.audio.tools")
            } header: {
                Text("Audio controls")
            } footer: {
                Text("Route and headset controls stay in Audio session tools, with explicit Activate/Deactivate "
                     + "actions. Shows the last reported audio state.")
            }
        }
        .navigationTitle("Audio")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("settings.audio.overview")
    }

    private var preferredDescription: String {
        state.preferred ?? preferredInput?.name ?? "Automatic · no preference reported"
    }

    private func valueRow(_ title: String, value: String, identifier: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Text(value).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("settings.audio.\(identifier)")
    }
}
