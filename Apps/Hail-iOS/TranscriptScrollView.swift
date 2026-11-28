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

struct TranscriptScrollState {
    var pinned = true
    private(set) var userScrolling = false

    /// Reconcile with the reader's final position and report whether to restore the semantic bottom anchor.
    mutating func updatePhase(_ phase: ScrollPhase, at viewport: TranscriptScrollViewport) -> Bool {
        let gestureEnded = userScrolling && phase == .idle
        userScrolling = phase == .interacting || phase == .decelerating
        if gestureEnded { pinned = viewport.nearBottom }
        return gestureEnded && pinned
    }
}

struct TranscriptScrollView<Content: View>: View {
    @ViewBuilder let content: (@escaping (String) -> Void) -> Content
    @Environment(\.stationPalette) private var palette
    @State private var position = ScrollPosition(idType: String.self, edge: .bottom)
    @State private var scroll = TranscriptScrollState()

    var body: some View {
        ScrollView {
            content { position.scrollTo(id: $0) }
        }
        .scrollBounceBehavior(.basedOnSize)
        .scrollPosition($position)
        .defaultScrollAnchor(.bottom, for: .initialOffset)
        .defaultScrollAnchor(scroll.pinned && !scroll.userScrolling ? .bottom : nil, for: .sizeChanges)
        .defaultScrollAnchor(.top, for: .alignment)
        .onScrollGeometryChange(for: TranscriptScrollViewport.self, of: TranscriptScrollViewport.init,
                                action: updatePin)
        .onScrollPhaseChange { _, phase, context in
            if scroll.updatePhase(phase, at: TranscriptScrollViewport(context.geometry)) {
                position.scrollTo(edge: .bottom)
            }
        }
        .overlay(alignment: .bottomTrailing) {
            if !scroll.pinned {
                Button("Jump to latest", systemImage: "arrow.down") {
                    scroll.pinned = true
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
        let follow = current.followsLatest(after: previous, wasPinned: scroll.pinned,
                                           userScrolling: scroll.userScrolling)
        if follow != scroll.pinned { scroll.pinned = follow }
        // SwiftUI follows the semantic edge as it lays out streamed text. Only request it again
        // if a manual scroll near the bottom cleared it and the scrollable extent then changed.
        if follow, !scroll.userScrolling, current.bottomOffset != previous.bottomOffset, position.edge != .bottom {
            position.scrollTo(edge: .bottom)
        }
    }
}
