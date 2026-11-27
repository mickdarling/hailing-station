import SwiftUI

/// The last reachable offset can move even when the reader hasn't scrolled.
struct TranscriptScrollViewport: Equatable {
    let bottomOffset: CGFloat
    let offset: CGFloat

    var nearBottom: Bool { bottomOffset - offset <= 32 }

    func followsLatest(after previous: Self, wasPinned: Bool, userScrolling: Bool) -> Bool {
        guard self != previous else { return wasPinned }
        if nearBottom { return true }
        let movedUp = offset < previous.offset
        if movedUp && (userScrolling || bottomOffset == previous.bottomOffset) { return false }
        return wasPinned
    }
}

extension TranscriptScrollViewport {
    init(_ geometry: ScrollGeometry) {
        self.init(bottomOffset: geometry.contentSize.height + geometry.contentInsets.bottom
                  - geometry.containerSize.height, offset: geometry.contentOffset.y)
    }
}

struct TranscriptScrollView<Content: View>: View {
    @ViewBuilder let content: (@escaping (String) -> Void) -> Content
    @Environment(\.stationPalette) private var palette
    @State private var position = ScrollPosition(idType: String.self, edge: .bottom)
    @State private var pinned = true
    @State private var userScrolling = false

    var body: some View {
        ScrollView {
            content { position.scrollTo(id: $0) }
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(pinned && !userScrolling ? .bottom : nil, for: .sizeChanges)
        .defaultScrollAnchor(.top, for: .alignment)
        .onScrollGeometryChange(for: TranscriptScrollViewport.self, of: TranscriptScrollViewport.init,
                                action: updatePin)
        .onScrollPhaseChange { _, phase, context in
            let wasScrolling = userScrolling
            userScrolling = phase == .interacting || phase == .decelerating
            if wasScrolling, phase == .idle, TranscriptScrollViewport(context.geometry).nearBottom {
                pinned = true
                position.scrollTo(edge: .bottom)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if !pinned {
                Button("Jump to latest", systemImage: "arrow.down") {
                    pinned = true
                    position.scrollTo(edge: .bottom)
                }
                .font(.caption.weight(.semibold))
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .tint(palette[.brand])
                .foregroundStyle(palette[.brandOnBrand])
                .accessibilityLabel("Jump to latest")
                .accessibilityIdentifier("station.transcript.jump-to-latest")
                .padding(8)
            }
        }
    }

    private func updatePin(_ previous: TranscriptScrollViewport, _ current: TranscriptScrollViewport) {
        let follow = current.followsLatest(after: previous, wasPinned: pinned, userScrolling: userScrolling)
        if follow != pinned { pinned = follow }
        // SwiftUI follows the semantic edge as it lays out streamed text. Only request it again
        // if a manual scroll near the bottom cleared it and the scrollable extent then changed.
        if follow, !userScrolling, current.bottomOffset != previous.bottomOffset, position.edge != .bottom {
            position.scrollTo(edge: .bottom)
        }
    }
}
