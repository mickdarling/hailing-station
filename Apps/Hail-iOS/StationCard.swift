import SwiftUI

extension View {
    func stationCard(minHeight: CGFloat = 320) -> some View {
        frame(maxWidth: .infinity, minHeight: minHeight)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }
}
