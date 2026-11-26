import HailCore
import SwiftUI

extension View {
    @ViewBuilder
    func stationBuildFooter() -> some View {
        #if os(macOS)
        if StationRedesignLaunch.flags.isOn(.shell) {
            // Keep the footer in the page's layout. A separately hosted inset took the whole detail's
            // accessibility frame when the Mac shell restored the Station after a section switch.
            VStack(spacing: 0) {
                self
                StationBuildFooter().fixedSize(horizontal: false, vertical: true)
            }
        } else {
            insetBuildFooter
        }
        #else
        insetBuildFooter
        #endif
    }

    private var insetBuildFooter: some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            // On iOS the inset is hosted separately and must leave the tree while the shell hides Station.
            StationBuildFooter().stationRemovedWhileHidden()
        }
    }
}

struct StationBuildFooter: View {
    private let info = StationBuildInfo()

    var body: some View {
        Text(info.label)
            .font(.caption)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .modifier(StationCanvasBackground(original: StationPlatform.background))
            .accessibilityIdentifier("station.build-info")
    }
}
