import HailCore
import SwiftUI

struct StationConnectionPresentation {
    let label: String
    let systemImage: String
    let color: Color
}

struct StationHeader<DestinationPicker: View>: View {
    let connection: StationConnectionPresentation
    @ViewBuilder let destinationPicker: DestinationPicker

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline) {
                    title
                    Spacer(minLength: 24)
                    connectionBadge
                }
                VStack(alignment: .leading, spacing: 10) {
                    title
                    connectionBadge
                }
            }
            destinationPicker
        }
        .padding(18)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
        .accessibilityElement(children: .contain)
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Hailing Station")
                .font(.largeTitle.bold())
            Text("Haley · voice terminal")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var connectionBadge: some View {
        Label(connection.label, systemImage: connection.systemImage)
            .font(.subheadline.weight(.semibold))
            .foregroundStyle(connection.color)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(connection.color.opacity(0.12), in: Capsule())
            .accessibilityIdentifier("station.connection")
            .accessibilityLabel("Connection status: \(connection.label)")
    }
}

struct AudioRouteSummaryView: View {
    @Bindable var model: AudioRouteModel

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 12) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 12) { routeControls }
                    VStack(spacing: 12) { routeControls }
                }
                Text(model.status)
                    .font(.caption)
                    .foregroundStyle(model.hasInputFailure ? Color.red : Color.secondary)
                    .lineLimit(2)
                if model.hasInputFailure {
                    Button {
                        Task { await model.retry() }
                    } label: {
                        Label("Retry microphone", systemImage: "arrow.clockwise")
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityHint("Retries the failed microphone route without changing your saved preference.")
                }
            }
        } label: {
            Label("Audio route", systemImage: "waveform.circle")
                .font(.headline)
        }
        .accessibilityIdentifier("station.audio-route")
    }

    @ViewBuilder
    private var routeControls: some View {
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
            routeTile(title: "Microphone", value: model.inputName, systemImage: "mic")
        }
        .disabled(model.inputs.isEmpty)
        .accessibilityIdentifier("station.microphone")
        .accessibilityLabel(model.inputAccessibilityLabel)
        .accessibilityHint(
            model.diagnostics.isActive
                ? "Opens the microphone list."
                : "Opens the microphone list and activates audio when you choose one."
        )

        AudioOutputRouteControl(outputName: model.outputName) {
            routeTile(title: "Output", value: model.outputName, systemImage: "speaker.wave.2")
        }
        .accessibilityIdentifier("station.output")
    }

    private func routeTile(title: String, value: String, systemImage: String) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(value)
                    .font(.subheadline.weight(.medium))
                    .lineLimit(1)
            }
        } icon: {
            Image(systemName: systemImage)
                .font(.title3)
                .frame(width: 28)
        }
        .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
    }
}
