import CoreFoundation
import Foundation
import Testing
@testable import HailCore

@Suite("Station redesign flags (#1115)")
struct StationRedesignFlagsTests {
    // Mick, 2026-11-26: "I'd prefer to keep the new look for new installs. I can always switch it back.
    // That part doesn't seem like it's degraded or going to revert."
    @Test func onlyNavigationStartsOnWithNothingStored() {
        let flags = StationRedesignFlags { _ in nil }
        for step in StationRedesignStep.allCases {
            #expect(flags.isOn(step) == (step == .shell))
        }
    }

    @Test(arguments: [Stored.missing, .int(1), .string("YES"), .array])
    func anUnlistedFutureStepStartsOff(stored: Stored) {
        #expect(!StationRedesignStep.isOn(forKey: "station.redesign.future", storedValue: stored.value))
    }

    @Test(arguments: [
        (Stored.bool(true), true),
        (.bool(false), false),
        (.missing, true),
        (.int(0), true),
        (.int(1), true),
        (.string("NO"), true),
        (.string("false"), true),
        (.string("YES"), true),
        (.string("true"), true),
        (.array, true)
    ])
    func onlyABooleanOverridesTheShellDefault(stored: Stored, on: Bool) {
        let flags = StationRedesignFlags { $0 == StationRedesignStep.shell.key ? stored.value : nil }
        #expect(flags.isOn(.shell) == on)
    }

    @MainActor @Test func numericPreferencesUseTheDefaultUntilLabsSavesABoolean() throws {
        let suite = "StationRedesignFlagsTests.\(UUID().uuidString)"
        let isolatedDefaults = UserDefaults(suiteName: suite)
        let defaults = try #require(isolatedDefaults)
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = StationRedesignStep.shell.key

        for value in [NSNumber(value: 0), NSNumber(value: 0.0), NSNumber(value: 1), NSNumber(value: 1.0)] {
            defaults.removeObject(forKey: key)
            defaults.set(value, forKey: key)
            let stored = defaults.object(forKey: key) as? NSNumber
            let raw = try #require(stored)
            #expect(CFGetTypeID(raw) != CFBooleanGetTypeID(), "Numeric fixture: \(Self.storedKind(raw))")
            let numeric = StationRedesignFlags { defaults.object(forKey: $0) }
            #expect(numeric.isOn(.shell))

            // An equal numeric 0/1 must not survive the user's explicit false/true.
            StationRedesignStep.shell.save(value.boolValue, in: defaults)
            let saved = defaults.object(forKey: key) as? NSNumber
            let choice = try #require(saved)
            #expect(CFGetTypeID(choice) == CFBooleanGetTypeID(), "Labs choice: \(Self.storedKind(choice))")
            let nextLaunch = StationRedesignFlags { defaults.object(forKey: $0) }
            #expect(nextLaunch.isOn(.shell) == value.boolValue)
        }
    }

    @MainActor @Test func freshBooleanAndOffToOnPreferencesUseActualBooleanFixtures() throws {
        let suite = "StationRedesignFlagsTests.\(UUID().uuidString)"
        let isolatedDefaults = UserDefaults(suiteName: suite)
        let defaults = try #require(isolatedDefaults)
        defer { defaults.removePersistentDomain(forName: suite) }
        let key = StationRedesignStep.shell.key
        defaults.removeObject(forKey: key)

        for value in [true, false, true] {
            defaults.set(value, forKey: key)
            let stored = defaults.object(forKey: key) as? NSNumber
            let raw = try #require(stored)
            #expect(CFGetTypeID(raw) == CFBooleanGetTypeID(), "Boolean fixture: \(Self.storedKind(raw))")
            #expect(raw.boolValue == value)
            let flags = StationRedesignFlags { defaults.object(forKey: $0) }
            #expect(flags.isOn(.shell) == value)
        }
    }

    private static func storedKind(_ raw: Any?) -> String {
        guard let raw else { return "missing" }
        let kind = String(reflecting: type(of: raw))
        guard let number = raw as? NSNumber else { return kind }
        return "\(kind), value=\(number), objc=\(String(cString: number.objCType)), "
            + "CFBoolean=\(CFGetTypeID(number) == CFBooleanGetTypeID())"
    }

    @Test func keysAreNamespacedPerStep() {
        #expect(StationRedesignStep.shell.key == "station.redesign.shell")
        let keys = StationRedesignStep.allCases.map(\.key)
        #expect(Set(keys).count == keys.count)
        #expect(keys.allSatisfy { $0.hasPrefix("station.redesign.") })
    }

    /// The safety point of the launch flags: a toggle changed while the app runs never changes the snapshot already
    /// taken, so the station is never rebuilt mid-session (and a capture never ended) until the next launch.
    @Test func aSnapshotIgnoresLaterChangesToTheStore() {
        let store = Store()
        store.values[StationRedesignStep.shell.key] = false
        let atLaunch = StationRedesignFlags(stored: store.value)
        store.values[StationRedesignStep.shell.key] = true
        #expect(!atLaunch.isOn(.shell))
        #expect(StationRedesignFlags(stored: store.value).isOn(.shell))

        let onAtLaunch = StationRedesignFlags(stored: store.value)
        store.values[StationRedesignStep.shell.key] = false
        #expect(onAtLaunch.isOn(.shell))
    }

    @Test func theSnapshotReadsEachKeyOnceAndNothingAfter() {
        let store = Store()
        let flags = StationRedesignFlags(stored: store.value)
        let reads = store.reads
        #expect(reads == StationRedesignStep.allCases.map(\.key))
        _ = flags.isOn(.shell)
        _ = flags.isOn(.shell)
        #expect(store.reads == reads)
    }
}

enum Stored: Sendable, CustomTestStringConvertible {
    case bool(Bool), int(Int), string(String), array, missing

    var value: Any? {
        switch self {
        case .bool(let value): value
        case .int(let value): value
        case .string(let value): value
        case .array: [false]
        case .missing: nil
        }
    }

    var testDescription: String { value.map { "\($0) (\(type(of: $0)))" } ?? "nil" }
}

private final class Store {
    var values: [String: Any] = [:]
    private(set) var reads: [String] = []

    func value(_ key: String) -> Any? {
        reads.append(key)
        return values[key]
    }
}
