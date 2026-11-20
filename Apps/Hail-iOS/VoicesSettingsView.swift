import HailCore
import SwiftUI

/// Values from the existing reply controller; this page has no playback or preference actions (#1115).
struct VoicesSettingsView<Tools: View>: View {
    let settings: ReplySegmentSettings
    @ViewBuilder let tools: () -> Tools

    var body: some View {
        Form {
            Section {
                valueRow("Pause between reply segments", value: seconds(settings.pauseAfterSegment), id: "pause")
                valueRow("Sustained sound to take the turn", value: seconds(settings.sustainedOnset), id: "onset")
                valueRow("Sound level", value: "\(number(settings.onsetThresholdDBFS)) dBFS", id: "threshold")
            } header: {
                Text("This device")
            } footer: {
                Text("These are the reply controller’s current settings. Any sustained sound can take the turn; "
                     + "this does not identify a speaker. A pause follows a segment marker that has actually played.")
            }
            Section {
                tools()
            } header: {
                Text("Turn-taking")
            } footer: {
                Text("Change the pause and sound level in Turn-taking. Sustained sound duration is shown for reference.")
            }
            Section("Voices on the Mac") {
                Text("Reply voices are generated on the Mac. This app cannot read or edit host, target or update-type "
                     + "voice assignments. No assignment is confirmed here.")
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("settings.voices.assignments-unavailable")
            }
        }
        .navigationTitle("Voices and replies")
        #if os(iOS)
        .navigationBarTitleDisplayMode(.inline)
        #endif
        .accessibilityIdentifier("settings.voices.overview")
    }

    private func valueRow(_ title: String, value: String, id: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline).foregroundStyle(.secondary)
            Text(value).fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("settings.voices.\(id)")
    }

    private func number(_ value: Double) -> String {
        value.formatted(.number.precision(.fractionLength(0...2)))
    }

    private func seconds(_ value: Double) -> String { "\(number(value)) seconds" }
}

/// The root supplies its existing playback instance; observing it neither configures nor controls audio.
struct VoicesSettingsOverview<Tools: View>: View {
    let playback: ReplyPlaybackController
    @ViewBuilder let tools: () -> Tools

    var body: some View {
        VoicesSettingsView(settings: playback.segmentSettings, tools: tools)
    }
}
