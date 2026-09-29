import HailCore
import SwiftUI

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
            .background(Color(uiColor: .systemGroupedBackground))
            .accessibilityIdentifier("station.build-info")
    }
}
