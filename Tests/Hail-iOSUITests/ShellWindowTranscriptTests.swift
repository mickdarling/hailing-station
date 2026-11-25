#if STATION_UI_FIXTURES
import XCTest

final class ShellWindowTranscriptTests: XCTestCase, ShellWindowUITestSupport {
    override func setUpWithError() throws {
        continueAfterFailure = false
        #if os(iOS) && !targetEnvironment(simulator)
        throw XCTSkip("Station display qualification requires a simulator.")
        #endif
    }

    @MainActor
    func testDocumentMatchesStationFramesInLightAndDark() {
        let app = application()
        let previous = XCUIDevice.shared.appearance
        defer { XCUIDevice.shared.appearance = previous }
        for style in [XCUIDevice.Appearance.light, .dark] {
            XCUIDevice.shared.appearance = style
            for state in ["ready", "listening", "held", "refused"] {
                launchDocument(state, in: app)
                let name = "station-\(state)" + (style == .dark ? "-dark-ours" : "-ours")
                screen("station.chat", named: name, in: app)
                app.terminate()
            }
        }
    }

    @MainActor
    func testDeliveryDetailsShowTheReplyDestination() {
        let app = application()
        launchDocument("ready", in: app)
        let details = element("station.transcript.details", in: app)
        reveal(details, in: app)
        activate(details)
        let sheet = element("station.transcript.delivery", in: app)
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))
        for name in ["Studio Mac", "Workbench"] {
            let field = NSPredicate(format: "label CONTAINS %@ OR value CONTAINS %@", name, name)
            XCTAssertTrue(sheet.descendants(matching: .any).matching(field).firstMatch.exists, name)
        }
        activate(app.buttons["Done"].firstMatch)
        XCTAssertTrue(sheet.waitForNonExistence(timeout: 5))
    }
}

@MainActor
private extension ShellWindowTranscriptTests {
    func application() -> XCUIApplication {
        #if os(macOS)
        let app = XCUIApplication(bundleIdentifier: "com.mickdarling.Hail-macOS-shell-tests")
        #else
        let app = XCUIApplication()
        let original = XCUIDevice.shared.orientation
        XCUIDevice.shared.orientation = device == "ipad" ? .landscapeLeft : .portrait
        addTeardownBlock { @MainActor in XCUIDevice.shared.orientation = original }
        #endif
        let reset = baseArguments + ["-reset-station-state"]
        addTeardownBlock { @MainActor in
            app.terminate()
            app.launchArguments = reset
            app.launch()
            app.terminate()
        }
        return app
    }

    func launchDocument(_ state: String, in app: XCUIApplication) {
        app.launchArguments = baseArguments + ["-reset-station-state", "-seed-navigation-shell",
                                               "-seed-station-state", state]
        launchStation(app)
        XCTAssertTrue(element("station.chat", in: app).waitForExistence(timeout: 10))
    }
}
#endif
