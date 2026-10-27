import Foundation
import Testing
@testable import HailCore

@Suite struct ReplySegmentSettingsTests {
    @Test func defaultsAndInclusiveBounds() {
        #expect(ReplySegmentSettings().pauseAfterSegment == 1.5)
        #expect(ReplySegmentSettings().sustainedOnset == 0.3)
        #expect(ReplySegmentSettings().onsetThresholdDBFS == -35)
        #expect(ReplySegmentSettings(onsetThresholdDBFS: -60).onsetThresholdDBFS == -60)
        #expect(ReplySegmentSettings(onsetThresholdDBFS: -15).onsetThresholdDBFS == -15)
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

    @Test(arguments: [-60.1, -14.9, .infinity, -.infinity, .nan])
    func invalidThresholdFallsBackIndependently(_ value: Double) {
        let settings = ReplySegmentSettings(pauseAfterSegment: 2, sustainedOnset: 0.5, onsetThresholdDBFS: value)
        #expect(settings.onsetThresholdDBFS == -35)
        #expect(settings.pauseAfterSegment == 2)
        #expect(settings.sustainedOnset == 0.5)
        #expect(ReplySegmentSettings(pauseAfterSegment: -1, onsetThresholdDBFS: -40).onsetThresholdDBFS == -40)
        #expect(ReplySegmentSettings(sustainedOnset: -1, onsetThresholdDBFS: -40).onsetThresholdDBFS == -40)
    }

    @Test func savingThresholdPreservesOtherSettingsAndUnknownKeys() throws {
        let suite = "ReplySegmentSettingsTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["pauseAfterSegment": 2.5, "sustainedOnset": 0.4, "future": 42],
                     forKey: ReplySegmentSettings.defaultsKey)
        let old = ReplySegmentSettings.saved(in: defaults)
        ReplySegmentSettings(pauseAfterSegment: old.pauseAfterSegment, sustainedOnset: old.sustainedOnset,
                             onsetThresholdDBFS: -40).save(in: defaults)
        let saved = ReplySegmentSettings.saved(in: defaults)
        #expect(saved.pauseAfterSegment == 2.5)
        #expect(saved.sustainedOnset == 0.4)
        #expect(saved.onsetThresholdDBFS == -40)
        #expect(defaults.dictionary(forKey: ReplySegmentSettings.defaultsKey)?["future"] as? Int == 42)
        defaults.set(["onsetThresholdDBFS": "invalid"], forKey: ReplySegmentSettings.defaultsKey)
        #expect(ReplySegmentSettings.saved(in: defaults).onsetThresholdDBFS == -35)
    }

    @Test func oneDefaultsValueRoundTripsAndValidatesStoredValues() throws {
        let suite = "ReplySegmentSettingsTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        #expect(ReplySegmentSettings.saved(in: defaults) == ReplySegmentSettings())
        let settings = ReplySegmentSettings(pauseAfterSegment: 2.5, sustainedOnset: 0.4)
        settings.save(in: defaults)
        #expect(ReplySegmentSettings.saved(in: defaults) == settings)
        #expect(defaults.dictionary(forKey: ReplySegmentSettings.defaultsKey)?.count == 3)
        defaults.set(["pauseAfterSegment": -2, "sustainedOnset": 0.7], forKey: ReplySegmentSettings.defaultsKey)
        #expect(ReplySegmentSettings.saved(in: defaults) == ReplySegmentSettings(sustainedOnset: 0.7))
        defaults.set(["pauseAfterSegment": "invalid"], forKey: ReplySegmentSettings.defaultsKey)
        #expect(ReplySegmentSettings.saved(in: defaults) == ReplySegmentSettings())
    }

    @Test func malformedValuesFallBackIndependently() throws {
        let defaults = try #require(SegmentSettingsDefaults(suiteName: "ReplySegmentSettingsTests-types"))
        let invalid: [Any] = [true, false, NSNumber(value: true), NSNumber(value: false),
                              "1", "0.5", "invalid", NSNull(), [1.0], ["nested": 1.0],
                              [NSNull()], ["nested": NSNull()]]
        for value in invalid {
            defaults.values = ["pauseAfterSegment": value, "sustainedOnset": NSNumber(value: 0.7)]
            #expect(ReplySegmentSettings.saved(in: defaults) == ReplySegmentSettings(sustainedOnset: 0.7))
            defaults.values = ["pauseAfterSegment": 2.5, "sustainedOnset": value]
            #expect(ReplySegmentSettings.saved(in: defaults) == ReplySegmentSettings(pauseAfterSegment: 2.5))
            defaults.values = ["pauseAfterSegment": 2.5, "sustainedOnset": 0.7, "onsetThresholdDBFS": value]
            #expect(ReplySegmentSettings.saved(in: defaults) == ReplySegmentSettings(
                pauseAfterSegment: 2.5, sustainedOnset: 0.7
            ))
        }
        defaults.values = ["pauseAfterSegment": NSNumber(value: 2), "sustainedOnset": 0.5]
        #expect(ReplySegmentSettings.saved(in: defaults) == ReplySegmentSettings(
            pauseAfterSegment: 2, sustainedOnset: 0.5
        ))
    }

    @Test func numericRepresentationsAreAcceptedIndependently() throws {
        let defaults = try #require(SegmentSettingsDefaults(suiteName: "ReplySegmentSettingsTests-numbers"))
        let numbers = [NSNumber(value: Int8(1)), NSNumber(value: Int16(1)), NSNumber(value: Int(1)),
                       NSNumber(value: Float(0.75)), NSNumber(value: Double(1.25))]
        for number in numbers {
            defaults.values = ["pauseAfterSegment": number, "sustainedOnset": 0.7]
            #expect(ReplySegmentSettings.saved(in: defaults) == ReplySegmentSettings(
                pauseAfterSegment: number.doubleValue, sustainedOnset: 0.7
            ))
            defaults.values = ["pauseAfterSegment": 2.5, "sustainedOnset": number]
            #expect(ReplySegmentSettings.saved(in: defaults) == ReplySegmentSettings(
                pauseAfterSegment: 2.5, sustainedOnset: number.doubleValue
            ))
        }
    }

    @Test func numericThresholdRepresentationsPreserveCompanions() throws {
        let defaults = try #require(SegmentSettingsDefaults(suiteName: "ReplySegmentSettingsTests-thresholds"))
        let numbers = [NSNumber(value: Int8(-40)), NSNumber(value: Int16(-40)), NSNumber(value: Int(-40)),
                       NSNumber(value: Float(-40.5)), NSNumber(value: Double(-40.25))]
        for number in numbers {
            defaults.values = ["pauseAfterSegment": 2.5, "sustainedOnset": 0.7, "onsetThresholdDBFS": number]
            #expect(ReplySegmentSettings.saved(in: defaults) == ReplySegmentSettings(
                pauseAfterSegment: 2.5, sustainedOnset: 0.7, onsetThresholdDBFS: number.doubleValue
            ))
        }
    }

    @Test(arguments: [true, false]) func persistedBooleansFallBackIndependently(_ value: Bool) throws {
        let suite = "ReplySegmentSettingsTests-\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(["pauseAfterSegment": value, "sustainedOnset": 0.7], forKey: ReplySegmentSettings.defaultsKey)
        #expect(ReplySegmentSettings.saved(in: defaults) == ReplySegmentSettings(sustainedOnset: 0.7))
        defaults.set(["pauseAfterSegment": 2.5, "sustainedOnset": value], forKey: ReplySegmentSettings.defaultsKey)
        #expect(ReplySegmentSettings.saved(in: defaults) == ReplySegmentSettings(pauseAfterSegment: 2.5))
        defaults.set(["pauseAfterSegment": 2.5, "sustainedOnset": 0.7, "onsetThresholdDBFS": value],
                     forKey: ReplySegmentSettings.defaultsKey)
        #expect(ReplySegmentSettings.saved(in: defaults) == ReplySegmentSettings(
            pauseAfterSegment: 2.5, sustainedOnset: 0.7
        ))
    }
}

// UserDefaults cannot persist NSNull; inject malformed dictionaries through the same read boundary.
private final class SegmentSettingsDefaults: UserDefaults, @unchecked Sendable {
    var values: [String: Any] = [:]
    override func dictionary(forKey defaultName: String) -> [String: Any]? { values }
}
