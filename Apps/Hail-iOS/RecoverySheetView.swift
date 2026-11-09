import HailCore
import SwiftUI

/// The recovery sheet (#1115): what the station observes first, then the last request, then a targeted next step.
/// It renders a `RecoverySheetState` and emits `RecoveryIntent`s, which only open a check or a choice. It never
/// retries, resends, flushes, interrupts, restarts or clears text; #1002 owns recovery.
struct RecoverySheetView: View {
    let state: RecoverySheetState
    let onIntent: (RecoveryIntent) -> Void

    var body: some View {
        List {
            Section {
                ForEach(state.steps) { step in
                    stepRow(step)
                }
            } header: {
                Text(state.header)
                    .font(.headline)
                    .accessibilityAddTraits(.isHeader)
            }
            if let request = state.request {
                Section("Last request") {
                    Label {
                        Text(request).fixedSize(horizontal: false, vertical: true)
                    } icon: {
                        Image(systemName: state.requestNeedsAttention ? "exclamationmark.triangle.fill" : "text.bubble")
                            .foregroundStyle(state.requestNeedsAttention ? Color.orange : Color.secondary)
                    }
                    .font(state.requestNeedsAttention ? .body.weight(.semibold) : .body)
                    .accessibilityIdentifier("recovery.request")
                    if let nextStep = state.nextStep {
                        Text(nextStep).font(.callout)
                    }
                }
            }
            Section("Next step") {
                ForEach(state.intents, id: \.self) { intent in
                    Button(title(intent)) { onIntent(intent) }
                        .accessibilityIdentifier("recovery.\(intent)")
                }
            }
        }
        .navigationTitle("Recovery")
    }

    private func stepRow(_ step: RecoveryStep) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(step.title).font(.subheadline.weight(.semibold))
                Text(step.text).font(.callout).foregroundStyle(.secondary)
            }
        } icon: {
            Image(systemName: symbol(step.state))
                .foregroundStyle(tint(step.state))
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(step.title): \(stateWord(step.state)). \(step.text)")
    }

    /// A shape per state, so no meaning rests on colour alone.
    private func symbol(_ state: RecoveryStep.State) -> String {
        switch state {
        case .confirmed: "checkmark.circle.fill"
        case .waiting: "clock"
        case .failed: "exclamationmark.triangle.fill"
        case .notApplicable: "minus.circle"
        }
    }

    private func tint(_ state: RecoveryStep.State) -> Color {
        switch state {
        case .confirmed: .green
        case .waiting: .secondary
        case .failed: .red
        case .notApplicable: .secondary
        }
    }

    private func stateWord(_ state: RecoveryStep.State) -> String {
        switch state {
        case .confirmed: "confirmed"
        case .waiting: "waiting"
        case .failed: "needs attention"
        case .notApplicable: "not needed"
        }
    }

    private func title(_ intent: RecoveryIntent) -> String {
        switch intent {
        case .inspectConnection: "Check the connection"
        case .chooseDestination: "Choose a destination"
        case .openListening: "Open listening controls"
        }
    }
}

#Preview("Recovery · synthetic") {
    let label = DestinationLabel(hostName: "Studio", targetName: "build", targetKind: "tmux", targetID: "%1")
    let state = RecoverySheetState.resolve(
        availability: .ready, destination: .confirmed(label), privacy: .unsupported,
        listening: (current: .starting, wasOn: true), turn: .noReplyYet)
    NavigationStack {
        RecoverySheetView(state: state, onIntent: { _ in })
    }
}
