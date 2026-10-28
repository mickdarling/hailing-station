import AVKit
import HailCore
import SwiftUI
struct AudioDiagnosticsView: View {
    @Bindable var model: AudioRouteModel
    @AppStorage(AudioInputPreferences.bluetoothHFPDefaultsKey) private var allowsBluetoothHFP = false
    @State private var bluetoothHFPFailure: String?

    var body: some View {
        List {
            Section("Session") {
                LabeledContent("State", value: model.diagnostics.isActive ? "Active" : "Inactive")
                LabeledContent("Sample rate", value: model.sampleRate)
                Text(model.status).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Activate") { Task { try? await model.activate() } }
                    Button("Deactivate") { Task { await model.deactivate() } }
                }
                .buttonStyle(.bordered)
            }
            Section("Input") {
                Menu {
                    if model.inputs.isEmpty {
                        Text("No microphones available")
                    } else {
                        Button {
                            Task { await model.select(nil) }
                        } label: {
                            if model.preferredInput == nil {
                                Label("Automatic", systemImage: "checkmark")
                            } else {
                                Text("Automatic")
                            }
                        }
                        ForEach(model.inputs) { input in
                            Button {
                                Task { await model.select(input) }
                            } label: {
                                if input.id == model.preferredInput?.id {
                                    Label(input.name, systemImage: "checkmark")
                                } else {
                                    Text(input.name)
                                }
                            }
                        }
                    }
                } label: {
                    routeControlLabel(
                        title: "Microphone",
                        value: model.inputName,
                        systemImage: "mic"
                    )
                }
                .disabled(!model.diagnostics.isActive || model.inputs.isEmpty)
                .accessibilityLabel(model.inputAccessibilityLabel)

                if let preferredStateDescription = model.preferredStateDescription {
                    LabeledContent("Preferred", value: preferredStateDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Output") {
                HStack {
                    routeControlLabel(
                        title: "Output",
                        value: model.outputName,
                        systemImage: "speaker.wave.2"
                    )
                    Spacer()
                    AudioOutputRoutePicker()
                        .frame(width: 44, height: 44)
                }
            }
            Section("Preference") {
                #if os(iOS)
                bluetoothHFPToggle
                #endif
                Text(allowsBluetoothHFP
                     ? "USB, wired headset, Bluetooth headset, then built-in microphone. Bluetooth HFP is on."
                     : "USB, wired headset, then built-in microphone. Bluetooth HFP is off.")
                    .font(.caption)
            }
        }
        .navigationTitle("Audio session")
        .stationToolBackNavigation()
        .task { await model.refresh() }
        // The root and capture controller own this shared session, including while a tool covers the station.
    }
}
private extension AudioDiagnosticsView {
    /// Off by default (#905). The session applies it at once when it is active, otherwise at its next start.
    private var bluetoothHFPToggle: some View {
        Toggle(isOn: $allowsBluetoothHFP) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Use AirPods / Bluetooth headset microphone")
                Text(bluetoothHFPFailure ?? "While on, AirPods switch to call-quality audio (mono, lower fidelity).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityIdentifier("audio.bluetooth-hfp-toggle")
        .onChange(of: allowsBluetoothHFP) { _, _ in
            Task {
                // The saved value, not the captured one, so quick toggles finish on the last choice.
                let allows = AudioInputPreferences.saved().allowsBluetoothHFP
                do {
                    try await (model.controller as? any AudioBluetoothHFPConfiguring)?.setAllowsBluetoothHFP(allows)
                    bluetoothHFPFailure = nil
                } catch {
                    bluetoothHFPFailure = "Applies when audio next starts: \(error.localizedDescription)"
                }
                await model.refresh()
            }
        }
    }

    private func routeControlLabel(title: String, value: String, systemImage: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(value).font(.subheadline).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: systemImage)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
#if os(iOS)
struct AudioOutputRoutePicker: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let picker = AVRoutePickerView()
        picker.prioritizesVideoDevices = false
        picker.tintColor = .secondaryLabel
        picker.activeTintColor = .systemIndigo
        picker.accessibilityLabel = "Choose audio output"
        picker.accessibilityHint = "Opens the system audio output list."
        return picker
    }

    func updateUIView(_ view: AVRoutePickerView, context: Context) {}
}
#else
/// macOS has no app-level output route: the system default plays replies. The button opens Sound settings,
/// where that default is chosen; the station never changes it itself.
struct AudioOutputRoutePicker: View {
    @Environment(\.openURL) private var openURL

    var body: some View {
        Button {
            if let url = URL(string: "x-apple.systempreferences:com.apple.Sound-Settings.extension") { openURL(url) }
        } label: {
            Image(systemName: "airplayaudio")
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Choose audio output")
        .accessibilityHint("Opens Sound settings, where the Mac's output is chosen.")
    }
}
#endif
