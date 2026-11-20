import Foundation
import Testing
@testable import HailCore

/// The app preference boundary, rather than the step arithmetic already covered by ConversationTextSizeTests.
@Suite("Conversation appearance preferences", .serialized)
@MainActor
struct ConversationAppearancePreferencesTests {
    @Test(arguments: [ConversationTextSize.Platform.touch, .mac])
    func aChangedChoiceAndResetSurviveOwnerRecreation(platform: ConversationTextSize.Platform) throws {
        try withDefaults { defaults, suite in
            defaults.set("Preserve this unrelated preference", forKey: "fixture.unrelated")
            let first = ConversationAppearancePreferences(defaults: defaults, platform: platform)
            #expect(first.state.isDefault)
            first.apply(.larger)
            let changed = first.state

            let reopenedDefaults = try #require(UserDefaults(suiteName: suite))
            let reopened = ConversationAppearancePreferences(defaults: reopenedDefaults, platform: platform)
            #expect(reopened.state == changed)
            #expect(!reopened.state.isDefault)
            reopened.apply(.reset)

            let afterReset = ConversationAppearancePreferences(defaults: defaults, platform: platform)
            #expect(afterReset.state.isDefault)
            #expect(afterReset.state.size == platform.defaultSize)
            #expect(defaults.string(forKey: "fixture.unrelated") == "Preserve this unrelated preference")
        }
    }

    @Test(arguments: [ConversationTextSize.Platform.touch, .mac])
    func repeatedBoundActionsPersistAValidChoice(platform: ConversationTextSize.Platform) throws {
        try withDefaults { defaults, _ in
            let preferences = ConversationAppearancePreferences(defaults: defaults, platform: platform)
            for _ in 0..<12 { preferences.apply(.larger) }
            #expect(!preferences.state.canGrow)
            let atLargest = ConversationAppearancePreferences(defaults: defaults, platform: platform)
            #expect(atLargest.state == preferences.state)

            for _ in 0..<12 { preferences.apply(.smaller) }
            #expect(!preferences.state.canShrink)
            let atSmallest = ConversationAppearancePreferences(defaults: defaults, platform: platform)
            #expect(atSmallest.state == preferences.state)
            #expect(defaults.object(forKey: ConversationTextSize.storageKey) as? Int == preferences.state.size)
        }
    }

    @Test func anInRangeLegacyIntegerUsesTheSharedNormalizationBeforeTheNextSave() throws {
        try withDefaults { defaults, _ in
            defaults.set(20, forKey: ConversationTextSize.storageKey)
            let preferences = ConversationAppearancePreferences(defaults: defaults, platform: .touch)
            #expect(preferences.state.size == 19)
            preferences.apply(.larger)
            #expect(defaults.object(forKey: ConversationTextSize.storageKey) as? Int == 21)
            #expect(ConversationAppearancePreferences(defaults: defaults, platform: .touch).state.size == 21)
        }
    }

    @Test(arguments: [ConversationTextSize.Platform.touch, .mac])
    func malformedStoredValuesFallBackAndTheNextActionRepairsOnlyThisKey(
        platform: ConversationTextSize.Platform
    ) throws {
        try withDefaults { defaults, _ in
            defaults.set("Unchanged", forKey: "fixture.unrelated")
            let malformed: [Any] = ["21", true, 21.5, [21], ["size": 21], -10, 1_000]
            for value in malformed {
                defaults.set(value, forKey: ConversationTextSize.storageKey)
                let preferences = ConversationAppearancePreferences(defaults: defaults, platform: platform)
                #expect(preferences.state.isDefault, "Unexpected stored value: \(value)")
                preferences.apply(.larger)
                #expect(!preferences.state.isDefault)
                #expect(defaults.object(forKey: ConversationTextSize.storageKey) as? Int == preferences.state.size)
                let reopened = ConversationAppearancePreferences(defaults: defaults, platform: platform)
                #expect(reopened.state == preferences.state)
                #expect(defaults.string(forKey: "fixture.unrelated") == "Unchanged")
            }
        }
    }

    private func withDefaults(_ operation: (UserDefaults, String) throws -> Void) throws {
        let suite = "ConversationAppearancePreferencesTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        try operation(defaults, suite)
    }
}
