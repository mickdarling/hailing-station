/// The native redesign's launch flags (#1115). Each adoption step ships behind one, off by default in every build,
/// so a build with a step merged looks and behaves exactly like the one before until Mick turns that step on in
/// Labs. Only merged steps are listed; each later step adds its own case.
public enum StationRedesignStep: String, CaseIterable, Sendable {
    /// Native navigation: tabs on iPhone, a sidebar on iPad and Mac.
    case shell

    /// The step's own preference key.
    public var key: String { "station.redesign.\(rawValue)" }

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

    /// `stored` returns a step key's stored value. A step is on only when that value is exactly `true`; anything
    /// else, missing or of another type, leaves it off.
    public init(stored: (String) -> Any?) {
        enabled = Set(StationRedesignStep.allCases.filter { stored($0.key) as? Bool == true })
    }

    public func isOn(_ step: StationRedesignStep) -> Bool { enabled.contains(step) }
}
