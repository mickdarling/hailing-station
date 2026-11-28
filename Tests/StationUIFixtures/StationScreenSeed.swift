#if STATION_UI_FIXTURES
#if !DEBUG
#error("Station display fixtures require a debug UI-test configuration.")
#endif

/// Synthetic Station states accepted by the UI-test app.
enum StationScreenSeed: String {
    case ready, offline, refused, held

    init?(arguments: [String], shellEnabled: Bool) {
        guard shellEnabled, arguments.contains("-seed-navigation-shell"),
              arguments.contains("-reset-station-state"),
              let index = arguments.firstIndex(of: "-seed-station-screen"),
              arguments.indices.contains(index + 1) else { return nil }
        self.init(rawValue: arguments[index + 1])
    }
}

#if os(iOS) && targetEnvironment(simulator)
import notify

enum StationFixtureStyle: String, CaseIterable {
    case light, dark
    static let environmentKey = "HAIL_UI_FIXTURE_STYLE"
    var notification: String { "com.mickdarling.Hail.ui-fixture.style." + rawValue }
    func request() { notify_post(notification) }
}
#endif
#endif
