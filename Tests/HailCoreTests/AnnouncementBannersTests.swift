import HailCore
import Testing

/// Unheard cues remain available one at a time, with a bounded backlog (#825).
@Suite struct AnnouncementBannersTests {
    @Test func orderAndCountFollowIndividualDismissals() {
        var banners = AnnouncementBanners()
        #expect(banners.current == nil)
        #expect(banners.pendingCount == 0)
        banners.dismissCurrent()
        banners.append("First")
        banners.append("Second")
        banners.append("Third")
        #expect(banners.current == "First")
        #expect(banners.pendingCount == 3)
        banners.dismissCurrent()
        #expect(banners.current == "Second")
        #expect(banners.pendingCount == 2)
        banners.dismissCurrent()
        #expect(banners.current == "Third")
        #expect(banners.pendingCount == 1)
        banners.dismissCurrent()
        #expect(banners.current == nil)
        #expect(banners.pendingCount == 0)
    }

    @Test func identicalTextsAreSeparateCues() {
        var banners = AnnouncementBanners()
        banners.append("Unheard")
        banners.append("Unheard")
        #expect(banners.pendingCount == 2)
        banners.dismissCurrent()
        #expect(banners.current == "Unheard")
        #expect(banners.pendingCount == 1)
    }

    @Test func theCapDropsTheOldestCues() {
        var banners = AnnouncementBanners()
        for index in 1...7 { banners.append("Cue \(index)") }
        #expect(banners.pendingCount == 5)
        for index in 3...7 {
            #expect(banners.current == "Cue \(index)")
            banners.dismissCurrent()
        }
        #expect(banners.current == nil)
        #expect(banners.pendingCount == 0)
    }
}
