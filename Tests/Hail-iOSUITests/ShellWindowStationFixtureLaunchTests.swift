#if STATION_UI_FIXTURES
import XCTest

/// Exercise the app's launch predicate in the UI-test configuration that contains it.
final class ShellWindowStationFixtureLaunchTests: XCTestCase {
    func testFixtureArgumentsCannotOverrideTheEffectiveShellSnapshot() {
        let arguments = ["-reset-station-state", "-seed-navigation-shell", "-seed-station-screen", "ready"]
        XCTAssertNil(StationScreenSeed(arguments: arguments, shellEnabled: false))
        XCTAssertEqual(StationScreenSeed(arguments: arguments, shellEnabled: true), .ready)
        for required in arguments {
            XCTAssertNil(StationScreenSeed(arguments: arguments.filter { $0 != required }, shellEnabled: true))
        }
        XCTAssertNil(StationScreenSeed(arguments: Array(arguments.dropLast()) + ["unknown"], shellEnabled: true))
    }
}
#endif
