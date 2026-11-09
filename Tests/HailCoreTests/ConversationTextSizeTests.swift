import Testing
@testable import HailCore

@Suite("Conversation text size (#1115)")
struct ConversationTextSizeTests {
    private func size(_ platform: ConversationTextSize.Platform = .touch, _ stored: Int?) -> ConversationTextSize {
        ConversationTextSize(platform: platform, stored: stored)
    }

    @Test func theDefaultsComeFromTheSpec() {
        #expect(size(.touch, nil).size == 17)
        #expect(size(.mac, nil).size == 14)
        #expect(size(.touch, nil).scale == 1)
        #expect(size(.touch, nil).label == "17 pt · default")
        #expect(size(.touch, nil).accessibilityValue == "17 points, default")
        #expect(size(.touch, 21).label == "21 pt")
        #expect(ConversationTextSize.storageKey == "hailing-station.conversation-text-size.v1")
    }

    // Jarvis, PR 8 plan: an in-range value snaps to the nearest step, ties going smaller; only nil, garbage or an
    // out-of-range value reads as the default.
    @Test func storedValuesSnapOrFallBack() {
        #expect(size(.touch, 18).size == 17)
        #expect(size(.touch, 20).size == 19)
        #expect(size(.touch, 23).size == 24)
        #expect(size(.mac, 15).size == 14)
        for garbage in [0, -3, 14, 25, 400] { #expect(size(.touch, garbage).size == 17, "\(garbage)") }
    }

    @Test func smallerAndLargerStopAtTheBounds() {
        let smallest = size(.touch, 15)
        #expect(!smallest.canShrink)
        #expect(smallest.boundNote == "Smallest")
        #expect(smallest.applying(.smaller) == smallest)
        let largest = size(.touch, 24)
        #expect(!largest.canGrow)
        #expect(largest.boundNote == "Largest")
        #expect(largest.applying(.larger) == largest)
        #expect(size(.touch, 17).applying(.larger).size == 19)
        #expect(size(.touch, 17).applying(.smaller).size == 16)
    }

    @Test func resetRestoresTheAppDefault() {
        #expect(size(.touch, 24).applying(.reset).size == 17)
        #expect(size(.mac, 20).applying(.reset).size == 14)
    }

    // The size multiplies on Dynamic Type: accessibility scales still apply, and the largest step isn't a cap.
    @Test func itMultipliesOnDynamicType() {
        #expect(size(.touch, nil).pointSize(bodyScale: 1) == 17)
        #expect(size(.touch, 24).pointSize(bodyScale: 3.1) == 24 * 3.1)
        #expect(size(.touch, 21).scale == 21.0 / 17.0)
    }
}
