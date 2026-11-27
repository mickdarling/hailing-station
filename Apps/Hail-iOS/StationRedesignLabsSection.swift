import Combine
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
            Text("Navigation is on by default. Turn it off to use the classic station. Changes apply after relaunch.")
        }
    }
}

private struct StationRedesignToggle: View {
    let step: StationRedesignStep
    @AppStorage private var storedIsOn: Bool
    @State private var hasMalformedValue: Bool

    init(step: StationRedesignStep) {
        self.step = step
        _storedIsOn = AppStorage(wrappedValue: step.isOnByDefault, step.key, store: .standard)
        _hasMalformedValue = State(initialValue: step.hasMalformedValue(in: .standard))
    }

    var body: some View {
        let isOn = hasMalformedValue ? step.isOnByDefault : storedIsOn
        VStack(alignment: .leading, spacing: 4) {
            Toggle(step.title, isOn: Binding(get: { isOn }, set: { choice in
                step.save(choice, in: .standard)
                hasMalformedValue = false
            }))
            .accessibilityIdentifier(step.key)
            if isOn != StationRedesignLaunch.flags.isOn(step) {
                Text("Relaunch to apply")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .accessibilityIdentifier("\(step.key).pending")
            }
        }
        // A repair in another window can change the raw type without changing AppStorage's coerced Bool.
        .onReceive(NotificationCenter.default.publisher(
            for: UserDefaults.didChangeNotification, object: UserDefaults.standard
        ).receive(on: RunLoop.main)) { _ in
            hasMalformedValue = step.hasMalformedValue(in: .standard)
        }
    }
}
