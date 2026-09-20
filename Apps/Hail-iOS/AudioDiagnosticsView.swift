import HailCore
import SwiftUI

struct AudioDiagnosticsView: View {
    let controller: any AudioSessionDiagnosticsProviding

    @State private var diagnostics = AudioSessionDiagnostics.inactive
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
                portRow(diagnostics.input, empty: "No input")
            }
            Section("Output") {
                if diagnostics.outputs.isEmpty {
                    Text("No output").foregroundStyle(.secondary)
                } else {
                    ForEach(diagnostics.outputs) { portRow($0, empty: "") }
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

    private var sampleRate: String {
        diagnostics.sampleRate == 0 ? "—" : "\(Int(diagnostics.sampleRate)) Hz"
    }

    @ViewBuilder
    private func portRow(_ port: AudioPort?, empty: String) -> some View {
        if let port {
            LabeledContent(port.name, value: port.kind.rawValue)
        } else {
            Text(empty).foregroundStyle(.secondary)
        }
    }

    private func activate() async {
        do {
            try await controller.activate()
            diagnostics = await controller.diagnostics
            status = "Preferred input applied"
        } catch {
            diagnostics = await controller.diagnostics
            status = "Activation failed: \(error.localizedDescription)"
        }
    }

    private func deactivate() async {
        await controller.deactivate()
        diagnostics = await controller.diagnostics
        status = "Inactive"
    }

    private func observe() async {
        diagnostics = await controller.diagnostics
        for await event in await controller.events {
            diagnostics = await controller.diagnostics
            switch event {
            case .routeChanged:
                status = "Route changed; preferred input reapplied"
            case .interruptionBegan:
                status = "Interrupted"
            case .interruptionEnded(let resumed):
                status = resumed ? "Resumed after interruption" : "Interruption ended; inactive"
            }
        }
    }
}
