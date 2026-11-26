import CoreFoundation
public import Foundation

/// The native redesign's launch flags (#1115). Each merged step has a Labs toggle and its own launch default.
public enum StationRedesignStep: String, CaseIterable, Sendable {
    /// Native navigation: tabs on iPhone, a sidebar on iPad and Mac.
    case shell

    /// The step's own preference key.
    public var key: String { "station.redesign.\(rawValue)" }

    /// Navigation is on by default. Future steps start off until explicitly listed here.
    public var isOnByDefault: Bool { Self.isOn(forKey: key, storedValue: nil) }

    /// Only a stored Boolean records a choice. A missing or malformed value uses this step's default.
    static func isOn(forKey key: String, storedValue: Any?) -> Bool {
        boolean(storedValue)?.boolValue ?? (key == shell.key)
    }

    private static func boolean(_ value: Any?) -> NSNumber? {
        guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { return nil }
        return number
    }

    /// A typed preference reader such as AppStorage may coerce malformed input to a Boolean.
    public func hasMalformedValue(in defaults: UserDefaults) -> Bool {
        guard let value = defaults.object(forKey: key) else { return false }
        return Self.boolean(value) == nil
    }

    /// Save an explicit Labs choice. Foundation can keep an equal NSNumber (e.g. 0 for false) on overwrite.
    public func save(_ enabled: Bool, in defaults: UserDefaults) {
        if hasMalformedValue(in: defaults) { defaults.removeObject(forKey: key) }
        defaults.set(enabled, forKey: key)
    }

    /// The name Labs shows beside the step's toggle.
    public var title: String {
        switch self {
        case .shell: "Navigation (tabs and sidebar)"
        }
    }
}

/// Which redesign steps are on, read once. It is a snapshot: a later change to the stored values never changes it,
/// so the app reads it once per launch and a step's toggle takes effect after the app is relaunched. Switching a
/// step mid-session would rebuild the station, which ends a capture.
public struct StationRedesignFlags: Equatable, Sendable {
    private let enabled: Set<StationRedesignStep>

    /// Reads each step's stored value once, honoring either Boolean choice over its launch default.
    public init(stored: (String) -> Any?) {
        enabled = Set(StationRedesignStep.allCases.filter { step in
            let key = step.key
            return StationRedesignStep.isOn(forKey: key, storedValue: stored(key))
        })
    }

    public func isOn(_ step: StationRedesignStep) -> Bool { enabled.contains(step) }
}
