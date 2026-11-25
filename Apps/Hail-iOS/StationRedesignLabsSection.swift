import HailCore
import SwiftUI

/// Labs' "Redesign" section: one toggle per merged step. A toggle only writes its step's preference; the app reads
/// it at the next launch, and the row says so until then.
struct StationRedesignLabsSection: View {
    var body: some View {
        Section {
            ForEach(StationRedesignStep.allCases, id: \.self) { StationRedesignToggle(step: $0) }
        } header: {
            Text("Redesign")
        } footer: {
            Text("Each one is off by default and takes effect after you relaunch Hailing Station.")
        }
    }
}

private struct StationRedesignToggle: View {
    let step: StationRedesignStep
    @AppStorage private var isOn: Bool

    init(step: StationRedesignStep) {
        self.step = step
        _isOn = AppStorage(wrappedValue: false, step.key)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Toggle(step.title, isOn: $isOn)
                .accessibilityIdentifier(step.key)
            if isOn != StationRedesignLaunch.flags.isOn(step) {
                Text("Relaunch to apply")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("\(step.key).pending")
            }
        }
    }
}
