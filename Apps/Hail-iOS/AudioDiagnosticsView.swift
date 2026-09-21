import AVKit
import HailCore
import SwiftUI
struct AudioDiagnosticsView: View {
    let controller: any AudioSessionDiagnosticsProviding

    @State private var diagnostics = AudioSessionDiagnostics.inactive
    @State private var inputs: [AudioPort] = []
    @State private var preferredInput: AudioPort?
    @State private var status = "Inactive"
    var body: some View {
        List {
            Section("Session") {
                LabeledContent("State", value: diagnostics.isActive ? "Active" : "Inactive")
                LabeledContent("Sample rate", value: sampleRate)
                Text(status).font(.caption).foregroundStyle(.secondary)
                HStack {
                    Button("Activate") { Task { await activate() } }
                    Button("Deactivate") { Task { await deactivate() } }
                }
                .buttonStyle(.bordered)
            }
            Section("Input") {
                Menu {
                    if inputs.isEmpty {
                        Text("No microphones available")
                    } else {
                        Button {
                            Task { await select(nil) }
                        } label: {
                            if preferredInput == nil {
                                Label("Automatic", systemImage: "checkmark")
                            } else {
                                Text("Automatic")
                            }
                        }
                        ForEach(inputs) { input in
                            Button {
                                Task { await select(input) }
                            } label: {
                                if input.id == preferredInput?.id {
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
                        value: diagnostics.input?.name ?? "No input",
                        systemImage: "mic"
                    )
                }
                .disabled(!diagnostics.isActive || inputs.isEmpty)
                .accessibilityLabel(inputAccessibilityLabel)

                if let preferredInput, preferredInput.id != diagnostics.input?.id {
                    LabeledContent("Preferred", value: preferredStateDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Section("Output") {
                HStack {
                    routeControlLabel(
                        title: "Output",
                        value: outputName,
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
        .task { await observe() }
        .onDisappear { Task { await controller.deactivate() } }
    }
}
private extension AudioDiagnosticsView {
    private var sampleRate: String {
        diagnostics.sampleRate == 0 ? "—" : "\(Int(diagnostics.sampleRate)) Hz"
    }

    private var outputName: String {
        let names = diagnostics.outputs.map(\.name)
        return names.isEmpty ? "No output" : names.joined(separator: ", ")
    }

    private var inputAccessibilityLabel: String {
        let active = diagnostics.input?.name ?? "no active microphone"
        guard let preferredInput, preferredInput.id != diagnostics.input?.id else {
            return "Microphone, \(active). Choose microphone."
        }
        return "Microphone, \(active). Preferred \(preferredStateDescription). Choose microphone."
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

    private func activate() async {
        do {
            try await controller.activate()
            await refresh()
            status = activeInputStatus
        } catch {
            diagnostics = await controller.diagnostics
            status = "Activation failed: \(error.localizedDescription)"
        }
    }

    private func deactivate() async {
        await controller.deactivate()
        await refresh()
        status = "Inactive"
    }

    private func select(_ input: AudioPort?) async {
        let name = input?.name ?? "Automatic"
        do {
            try await controller.selectInput(id: input?.id)
            await refresh()
            status = input.map { "Using \($0.name)" } ?? activeInputStatus
        } catch {
            await refresh()
            status = "Could not select \(name): \(error.localizedDescription)"
        }
    }

    private func observe() async {
        await refresh()
        for await event in await controller.events {
            await refresh()
            switch event {
            case .routeChanged:
                status = routeChangeStatus
            case .interruptionBegan:
                status = "Interrupted"
            case .interruptionEnded(let resumed):
                status = resumed ? "Resumed after interruption" : "Interruption ended; inactive"
            }
        }
    }

    private func refresh() async {
        diagnostics = await controller.diagnostics
        inputs = await controller.availableInputs
        preferredInput = await controller.preferredInput
    }

    private var routeChangeStatus: String {
        guard let preferredInput, preferredInput.id != diagnostics.input?.id else {
            return "Route changed"
        }
        return "Route changed; preferred \(preferredInput.name) is not active"
    }

    private var preferredStateDescription: String {
        guard let preferredInput else { return "Automatic" }
        let availability = inputs.contains { $0.id == preferredInput.id }
        return "\(preferredInput.name) · \(availability ? "not active" : "unavailable")"
    }

    private var activeInputStatus: String {
        guard let preferredInput, preferredInput.id != diagnostics.input?.id else {
            return diagnostics.input.map { "Using \($0.name)" } ?? "Active with no microphone"
        }
        return "Active; preferred \(preferredStateDescription)"
    }
}
private struct AudioOutputRoutePicker: UIViewRepresentable {
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
