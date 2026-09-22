import AVKit
import HailCore
import SwiftUI
struct AudioDiagnosticsView: View {
    @Bindable var model: AudioRouteModel

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
                Text("USB, wired headset, then built-in microphone. Bluetooth HFP is disabled.")
                    .font(.caption)
            }
        }
        .navigationTitle("Audio session")
        .task { await model.refresh() }
        .onDisappear { Task { await model.deactivate() } }
    }
}
private extension AudioDiagnosticsView {
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
