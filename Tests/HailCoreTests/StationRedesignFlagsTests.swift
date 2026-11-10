import Testing
@testable import HailCore

@Suite("Station redesign flags (#1115)")
struct StationRedesignFlagsTests {
    @Test func everyStepIsOffWithNothingStored() {
        let flags = StationRedesignFlags { _ in nil }
        for step in StationRedesignStep.allCases {
            #expect(!flags.isOn(step))
        }
    }

    @Test(arguments: [
        (Stored.bool(true), true),
        (.bool(false), false),
        (.missing, false),
        (.int(1), false),
        (.string("YES"), false),
        (.string("true"), false)
    ])
    func aStepIsOnOnlyWhenItsValueIsExactlyTrue(stored: Stored, on: Bool) {
        let flags = StationRedesignFlags { $0 == StationRedesignStep.shell.key ? stored.value : nil }
        #expect(flags.isOn(.shell) == on)
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
    case bool(Bool), int(Int), string(String), missing

    var value: Any? {
        switch self {
        case .bool(let value): value
        case .int(let value): value
        case .string(let value): value
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
