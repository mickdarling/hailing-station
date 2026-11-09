import Testing
@testable import HailCore

/// The text size's promises over every stored value and intent sequence (#1115).
@Suite("Conversation text size sweep (#1115)")
struct ConversationTextSizeSweepTests {
    private static let intents: [ConversationTextSize.Intent] = [.smaller, .larger, .reset]

    @Test(arguments: [ConversationTextSize.Platform.touch, .mac])
    func everyStoredValueAndIntentKeepsAListedStep(platform: ConversationTextSize.Platform) {
        let steps = platform.steps
        let stored: [Int?] = [nil] + Array(-5...40).map { Optional($0) }
        for value in stored {
            let start = ConversationTextSize(platform: platform, stored: value)
            #expect(steps.contains(start.size), "\(String(describing: value))")
            checkSnap(start, stored: value)
            // Every sequence of three intents stays on the list; Reset always gives the default.
            for first in Self.intents {
                for second in Self.intents {
                    for third in Self.intents {
                        let end = start.applying(first).applying(second).applying(third)
                        #expect(steps.contains(end.size), "\(String(describing: value)) \(first) \(second) \(third)")
                        if third == .reset { #expect(end.isDefault) }
                    }
                }
            }
            #expect((start.scale == 1) == start.isDefault)
            #expect(start.applying(.smaller).size <= start.size)
            #expect(start.applying(.larger).size >= start.size)
        }
    }

    // Jarvis, PR 8 plan: an in-range value moves by at most half the gap between its neighbouring steps.
    private func checkSnap(_ state: ConversationTextSize, stored: Int?) {
        let steps = state.platform.steps
        guard let stored, let low = steps.first, let high = steps.last, (low...high).contains(stored) else {
            #expect(state.isDefault, "\(String(describing: stored))")
            return
        }
        let below = steps.last { $0 <= stored } ?? low
        let above = steps.first { $0 >= stored } ?? high
        #expect(abs(state.size - stored) * 2 <= above - below, "\(stored)")
        #expect(state.size == below || state.size == above, "\(stored)")
    }
}
