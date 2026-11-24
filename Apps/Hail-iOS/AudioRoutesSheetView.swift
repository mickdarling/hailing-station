import HailCore
import SwiftUI

/// The audio routes sheet (#1115): the microphone in use and the output playing, kept apart, with the existing
/// microphone preference and the system output picker. It renders an `AudioRoutesSheetState` and emits
/// `AudioRoutesIntent`s; the audio owner applies them. Opening or reading it never activates or deactivates audio.
struct AudioRoutesSheetView: View {
    @Environment(\.stationPalette) private var palette
    let state: AudioRoutesSheetState
    let onIntent: (AudioRoutesIntent) -> Void

    var body: some View {
        List {
            microphone.listRowBackground(palette[.elevatedSurface])
            Section("Output") {
                HStack {
                    LabeledContent("Playing to", value: state.output)
                    AudioOutputRoutePicker()
                        .frame(width: 44, height: 44)
                }
            }
            .listRowBackground(palette[.elevatedSurface])
            if let hfp = state.hfp {
                bluetoothHeadset(hfp).listRowBackground(palette[.elevatedSurface])
            }
        }
        .scrollContentBackground(.hidden)
        .background(palette[.surface])
        .foregroundStyle(palette[.textPrimary], palette[.textSecondary])
        .navigationTitle("Audio routes")
    }

    private var microphone: some View {
        Section {
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent("Active", value: state.activeInput)
                if let preferred = state.preferred {
                    Text("Preferred: \(preferred)").font(.caption).foregroundStyle(palette[.textSecondary])
                }
                Text(state.status).font(.caption).foregroundStyle(palette[.textSecondary])
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(state.microphoneAccessibilityLabel)
            .accessibilityIdentifier("audio-routes.microphone")
            if let failure = state.failure {
                Text(failure)
                    .font(.callout)
                    .foregroundStyle(palette[.stateWarning])
                    .accessibilityIdentifier("audio-routes.failure")
            }
            if state.showsRetry {
                Button("Retry microphone", systemImage: "arrow.clockwise") { onIntent(.retryInput) }
                    .disabled(!state.choicesEnabled)
                    .accessibilityHint("Applies the saved microphone preference again.")
            }
            ForEach(state.choices) { choice in
                Button {
                    onIntent(choice.intent)
                } label: {
                    LabeledContent(choice.name) {
                        if choice.isPreferred { Image(systemName: "checkmark").accessibilityHidden(true) }
                    }
                }
                .disabled(!state.choicesEnabled)
                .accessibilityAddTraits(choice.isPreferred ? .isSelected : [])
            }
        } header: {
            Text("Microphone")
        } footer: {
            if let reason = state.disabledReason { Text(reason) }
        }
    }

    private func bluetoothHeadset(_ hfp: HFPOption) -> some View {
        Section {
            Toggle(isOn: Binding(get: { hfp.isOn }, set: { onIntent(.setBluetoothHFP($0)) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Use AirPods / Bluetooth headset microphone")
                    if let caption = state.hfpCaption {
                        Text(caption).font(.caption).foregroundStyle(palette[.textSecondary])
                    }
                }
            }
            .accessibilityIdentifier("audio-routes.bluetooth-hfp")
        } footer: {
            Text("Off by default.")
        }
    }
}

#Preview("Audio routes · synthetic") {
    let builtIn = AudioPort(id: "built-in", name: "iPhone Microphone", kind: .builtIn)
    let usb = AudioPort(id: "usb", name: "USB Microphone", kind: .usb)
    let speaker = AudioPort(id: "speaker", name: "Speaker", kind: .other)
    let state = AudioRoutesSheetState.resolve(
        diagnostics: AudioSessionDiagnostics(isActive: true, input: builtIn, outputs: [speaker], sampleRate: 48_000),
        inputs: [builtIn, usb], preferred: usb,
        selection: AudioInputSelectionState(
            resolution: .failed, preferred: usb, attempted: usb, active: builtIn,
            failureDescription: "The route was not confirmed"),
        hfp: HFPOption(isOn: false, failure: nil))
    NavigationStack {
        AudioRoutesSheetView(state: state, onIntent: { _ in })
    }
}
