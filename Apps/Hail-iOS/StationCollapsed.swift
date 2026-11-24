import SwiftUI

extension View {
    /// Keeps a surface mounted, and so running, while the conversation is full screen, but takes no space, cannot be
    /// seen or tapped, and is left out for VoiceOver (#819).
    @ViewBuilder
    func stationCollapsed(_ collapsed: Bool) -> some View {
        frame(width: collapsed ? 0 : nil, height: collapsed ? 0 : nil)
            .clipped()
            .opacity(collapsed ? 0 : 1)
            .allowsHitTesting(!collapsed)
            .accessibilityHidden(collapsed)
    }
}
