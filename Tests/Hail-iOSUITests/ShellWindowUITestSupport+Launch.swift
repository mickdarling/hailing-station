import XCTest
#if os(macOS)
import AppKit
#endif

enum ClassicStationFixture {
    static let seed = "-seed-classic-shell"
    static let resetArguments = ["-reset-station-state", seed]

    @MainActor
    static func application(reset: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments += reset ? resetArguments : [seed]
        return app
    }
}

@MainActor
extension ShellWindowUITestSupport {
    var baseArguments: [String] {
        #if os(macOS)
        // The isolated window must never discover or connect to a configured local host.
        ["-hailing-station.local-host-offered.v1", "YES"]
        #else
        []
        #endif
    }

    func launchStation(shellEnabled: Bool, arguments: [String] = []) -> XCUIApplication {
        let seed = shellEnabled ? "-seed-navigation-shell" : ClassicStationFixture.seed
        let app = launchStation(arguments: [seed] + arguments)
        if shellEnabled { XCTAssertTrue(section("station", in: app).waitForExistence(timeout: 10)) }
        return app
    }

    func launchStation(arguments: [String] = []) -> XCUIApplication {
        #if os(macOS)
        let app = XCUIApplication(bundleIdentifier: "com.mickdarling.Hail-macOS-shell-tests")
        #else
        let app = XCUIApplication()
        let orientation = XCUIDevice.shared.orientation
        if device == "ipad" { XCUIDevice.shared.orientation = .landscapeLeft }
        #endif
        let reset = baseArguments + ["-reset-station-state"]
        addTeardownBlock { @MainActor in
            app.terminate()
            app.launchArguments = reset
            app.launch()
            app.terminate()
            #if os(iOS)
            XCUIDevice.shared.orientation = orientation
            #endif
        }
        app.launchArguments = reset + arguments
        launchStation(app)
        #if os(macOS)
        XCTAssertEqual(app.windows.matching(identifier: "station").count, 1, "There must be one Station window")
        #endif
        return app
    }

    func launchStation(_ app: XCUIApplication) {
        #if os(macOS)
        // The first screen is the primary display, independent of the previous key window or focused display.
        guard let primary = NSScreen.screens.first else {
            XCTFail("Station UI tests require a primary display")
            return
        }
        let visible = primary.visibleFrame
        #if STATION_UI_FIXTURES
        let usesTranscriptFrame = app.launchArguments.contains("-seed-station-state")
        let width = min(usesTranscriptFrame ? 1_380 : 900, visible.width)
        let height = min(usesTranscriptFrame ? 831 : 672, visible.height)
        #else
        let width = min(900, visible.width)
        let height = min(672, visible.height)
        #endif
        let frame = CGRect(x: floor(visible.midX - width / 2), y: floor(visible.midY - height / 2),
                           width: width, height: height)
        app.launchEnvironment["SHELL_UI_TEST_WINDOW_FRAME"] = NSStringFromRect(frame)
        app.launch()
        // XCTest measures from the primary display's top edge. AppKit measures from its bottom edge.
        let expected = CGRect(x: frame.minX, y: primary.frame.maxY - frame.maxY, width: width, height: height)
        let window = stationWindow(in: app)
        XCTAssertTrue(window.waitForExistence(timeout: 10))
        XCTAssertTrue(window.wait(for: \.frame, toEqual: expected, timeout: 10),
                      "Station should open at \(expected) on the primary display")
        #else
        app.launch()
        #endif
    }
}
