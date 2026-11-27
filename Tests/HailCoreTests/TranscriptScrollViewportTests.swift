import SwiftUI
import Testing

struct TranscriptScrollViewportTests {
    @Test func nearBottomIncludesTheThresholdAndShortDocuments() {
        let end = TranscriptScrollViewport(bottomOffset: 500, offset: 500)
        let near = TranscriptScrollViewport(bottomOffset: 500, offset: 468)
        let history = TranscriptScrollViewport(bottomOffset: 500, offset: 467)
        #expect(near.followsLatest(after: end, wasPinned: true, userScrolling: true))
        #expect(!history.followsLatest(after: near, wasPinned: true, userScrolling: true))
        #expect(near.followsLatest(after: history, wasPinned: false, userScrolling: true))
        #expect(TranscriptScrollViewport(bottomOffset: -10, offset: 0).nearBottom)
    }

    @Test func growthPreservesIntentEvenWhenTheNewBottomIsFarAway() {
        let before = TranscriptScrollViewport(bottomOffset: 500, offset: 475)
        let append = TranscriptScrollViewport(bottomOffset: 600, offset: 475)
        let stream = TranscriptScrollViewport(bottomOffset: 840, offset: 475)
        let catchingUp = TranscriptScrollViewport(bottomOffset: 840, offset: 700)
        #expect(append.followsLatest(after: before, wasPinned: true, userScrolling: false))
        #expect(stream.followsLatest(after: append, wasPinned: true, userScrolling: false))
        #expect(catchingUp.followsLatest(after: stream, wasPinned: true, userScrolling: false))
        #expect(!stream.followsLatest(after: append, wasPinned: false, userScrolling: false))
    }

    @Test func scrollingIntoHistoryDuringGrowthWinsOverThePin() {
        let before = TranscriptScrollViewport(bottomOffset: 500, offset: 500)
        let after = TranscriptScrollViewport(bottomOffset: 600, offset: 400)
        #expect(!after.followsLatest(after: before, wasPinned: true, userScrolling: true))
        #expect(after.followsLatest(after: before, wasPinned: true, userScrolling: false))
    }

    @Test(arguments: [true, false])
    func gestureEndingAfterGrowthUsesTheFinalDistanceToBottom(endsNearBottom: Bool) {
        let before = TranscriptScrollViewport(bottomOffset: 500, offset: 475)
        let grown = TranscriptScrollViewport(bottomOffset: 600, offset: 475)
        let end = TranscriptScrollViewport(bottomOffset: 600, offset: endsNearBottom ? 570 : 510)
        var scroll = TranscriptScrollState()
        _ = scroll.updatePhase(.interacting, at: before)
        scroll.pinned = grown.followsLatest(after: before, wasPinned: scroll.pinned,
                                            userScrolling: scroll.userScrolling)
        #expect(scroll.pinned)
        _ = scroll.updatePhase(.decelerating, at: grown)
        let restoreAnchor = scroll.updatePhase(.idle, at: end)
        #expect(restoreAnchor == endsNearBottom)
        #expect(scroll.pinned == endsNearBottom)
    }

    @Test func bottomOffsetIncludesTheBottomInset() {
        let geometry = ScrollGeometry(contentOffset: CGPoint(x: 0, y: 300),
                                      contentSize: CGSize(width: 400, height: 800),
                                      contentInsets: EdgeInsets(top: 0, leading: 0, bottom: 40, trailing: 0),
                                      containerSize: CGSize(width: 400, height: 500))
        let viewport = TranscriptScrollViewport(geometry)
        #expect(viewport.bottomOffset == 340)
        #expect(!viewport.nearBottom)
    }
}
