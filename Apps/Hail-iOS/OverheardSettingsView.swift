import HailCore
import SwiftUI

/// Overheard remarks (#398): whether the chat shows what ambient listening heard but did not send, and whose. Hidden
/// and owner-only by default; the host is told only while shown, so nothing overheard leaves the Mac otherwise.
struct OverheardSettingsView: View {
    static let showKey = "overheard.show"
    static let whoseKey = "overheard.whose"

    let connections: HostConnectionStore
    @AppStorage(OverheardSettingsView.showKey) private var show = false
    @AppStorage(OverheardSettingsView.whoseKey) private var whose = "owner"

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Show overheard remarks", isOn: $show)
                .font(.subheadline)
                .accessibilityHint("Shows, greyed, what ambient listening heard but did not send")
                .accessibilityIdentifier("station.overheard-toggle")
            if show {
                Picker("Whose", selection: $whose) {
                    Text("Just me").tag("owner")
                    Text("Everyone").tag("everyone")
                }
                .pickerStyle(.segmented)
                .accessibilityIdentifier("station.overheard-whose")
            }
        }
        .onAppear(perform: apply)
        .onChange(of: show) { _, _ in apply() }
        .onChange(of: whose) { _, _ in apply() }
    }

    private func apply() {
        connections.setOverheardScope(show ? whose : "off")
    }
}
