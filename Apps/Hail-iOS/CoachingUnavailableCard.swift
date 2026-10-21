import SwiftUI

/// Private coaching is Mac-only for now (#611). iPhone and iPad show where it will live, disabled, until the
/// mobile coaching work (#604) lands. It sits in the listening column, where the Mac drafts put their coaching card.
struct CoachingUnavailableCard: View {
    /// Placeholder wording; Mick decides the final text (#611).
    static let message = "Private coaching is not yet available on iPhone/iPad."

    var body: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text(Self.message)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("station.coaching-unavailable-message")
                Button("Start", systemImage: "ear") {}
                    .buttonStyle(.bordered)
                    .disabled(true)
                    .accessibilityLabel("Start private coaching")
                    .accessibilityHint(Self.message)
                    .accessibilityIdentifier("station.coaching-start")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } label: {
            Label("Private coaching", systemImage: "ear.badge.waveform")
                .font(.headline)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("station.coaching-unavailable")
    }
}
