import HailCore
import SwiftUI

/// Each unheard cue can be dismissed without losing the next one (#825).
struct AnnouncementBannerView: View {
    @Binding var banners: AnnouncementBanners

    var body: some View {
        if let banner = banners.current {
            Button { banners.dismissCurrent() } label: {
                VStack(spacing: 2) {
                    Label(banner, systemImage: "speaker.slash")
                    if banners.pendingCount > 1 {
                        Text("\(banners.pendingCount - 1) more").font(.caption)
                    }
                }
            }
            .buttonStyle(.plain)
            .font(.subheadline.weight(.semibold))
            .padding(EdgeInsets(top: 10, leading: 14, bottom: 10, trailing: 14))
            .background(.regularMaterial, in: Capsule())
            .padding(.top, 8)
            .accessibilityHint("Tap to dismiss this announcement.")
            .accessibilityIdentifier("station.announcement-banner")
        }
    }
}
