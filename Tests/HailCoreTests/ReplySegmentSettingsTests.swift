import Foundation
import Testing
@testable import HailCore

@Suite struct ReplySegmentSettingsTests {
    @Test func defaultsAndInclusiveBounds() {
        #expect(ReplySegmentSettings().pauseAfterSegment == 1.5)
        #expect(ReplySegmentSettings().sustainedOnset == 0.3)
        #expect(ReplySegmentSettings(pauseAfterSegment: 0.1, sustainedOnset: 0.05).pauseAfterSegment == 0.1)
        #expect(ReplySegmentSettings(pauseAfterSegment: 10, sustainedOnset: 2).sustainedOnset == 2)
    }

    @Test(arguments: [-1.0, 0, 10.1, .infinity, -.infinity, .nan])
    func invalidPauseFallsBackWithoutChangingOnset(_ value: Double) {
        let settings = ReplySegmentSettings(pauseAfterSegment: value, sustainedOnset: 0.5)
        #expect(settings.pauseAfterSegment == 1.5)
        #expect(settings.sustainedOnset == 0.5)
    }

    @Test(arguments: [-1.0, 0, 2.1, .infinity, -.infinity, .nan])
    func invalidOnsetFallsBackWithoutChangingPause(_ value: Double) {
        let settings = ReplySegmentSettings(pauseAfterSegment: 2, sustainedOnset: value)
        #expect(settings.pauseAfterSegment == 2)
        #expect(settings.sustainedOnset == 0.3)
    }

    @Test func oneDefaultsValueRoundTripsAndValidatesStoredValues() throws {
        let suite = "ReplySegmentSettingsTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(ReplySegmentSettings.saved(in: defaults) == ReplySegmentSettings())
        let settings = ReplySegmentSettings(pauseAfterSegment: 2.5, sustainedOnset: 0.4)
        settings.save(in: defaults)
        #expect(ReplySegmentSettings.saved(in: defaults) == settings)
        #expect(defaults.dictionary(forKey: ReplySegmentSettings.defaultsKey)?.count == 2)
        defaults.set(["pauseAfterSegment": -2, "sustainedOnset": 0.7], forKey: ReplySegmentSettings.defaultsKey)
        #expect(ReplySegmentSettings.saved(in: defaults) == ReplySegmentSettings(sustainedOnset: 0.7))
        defaults.set(["pauseAfterSegment": "invalid"], forKey: ReplySegmentSettings.defaultsKey)
        #expect(ReplySegmentSettings.saved(in: defaults) == ReplySegmentSettings())
    }
}
