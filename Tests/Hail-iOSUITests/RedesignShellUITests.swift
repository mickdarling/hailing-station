import XCTest

/// The redesign's Shell step (#1115): off by default, turned on from Labs, applied only after a relaunch, and the
/// station stays mounted while another section shows.
final class RedesignShellUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        if ProcessInfo.processInfo.environment["SIMULATOR_UDID"] == nil {
            throw XCTSkip("Redesign shell coverage runs in the simulator matrix.")
        }
    }

    @MainActor
    func testShellAppliesOnlyAfterRelaunchAndKeepsTheStationMounted() throws {
        let app = XCUIApplication()
        let isPad = UIDevice.current.userInterfaceIdiom == .pad
        // Landscape, so an iPad shows its sidebar without the system's reveal button.
        if isPad { XCUIDevice.shared.orientation = .landscapeLeft }
        addTeardownBlock { @MainActor in
            // A reset launch turns every redesign flag off again, so no other test sees the shell.
            app.terminate()
            app.launchArguments = ["-reset-station-state"]
            app.launch()
            app.terminate()
            XCUIDevice.shared.orientation = .portrait
        }

        app.launchArguments = ["-reset-station-state"]
        app.launch()
        XCTAssertTrue(app.staticTexts["Hailing Station"].waitForExistence(timeout: 10))
        XCTAssertFalse(section("devices", in: app, isPad: isPad).exists, "The shell is off by default")

        turnOnShellInLabs(app)
        // Mid-run, the toggle changes nothing: the station is still today's, with no tabs or sidebar.
        XCTAssertTrue(app.staticTexts["Hailing Station"].waitForExistence(timeout: 5))
        XCTAssertFalse(section("devices", in: app, isPad: isPad).exists, "The shell must wait for a relaunch")

        app.terminate()
        app.launchArguments = []
        app.launch()
        let devices = section("devices", in: app, isPad: isPad)
        XCTAssertTrue(devices.waitForExistence(timeout: 10), "The shell applies after a relaunch")
        // The header labels its icon and its text with the same identifier, so take the first of them.
        let connection = app.descendants(matching: .any)["station.connection"].firstMatch
        XCTAssertTrue(connection.waitForExistence(timeout: 10))

        devices.tap()
        XCTAssertTrue(app.descendants(matching: .any)["station.devices.mac-setup"].waitForExistence(timeout: 5))
        // The station stays mounted behind another section (a remount would end a capture), and nothing of it is in
        // the accessibility tree, so VoiceOver never reads its microphone or privacy state from there.
        try assertNoStation(in: app, named: "devices-shown")

        section("station", in: app, isPad: isPad).tap()
        waitUntilHittable(connection, in: app, named: "station-restored")

        // In the shell a station tool opens its section instead of pushing under the station.
        openStationTool("Labs", in: app, opens: app.navigationBars["Settings"])
        try assertNoStation(in: app, named: "settings-shown")
        section("station", in: app, isPad: isPad).tap()
        waitUntilHittable(connection, in: app, named: "station-restored-from-settings")
    }

    /// Nothing of the station is in the accessibility tree: no identifier in its namespace beyond the shell's own, and
    /// none of its sensitive wording. A sweep of the whole tree, so a later toolbar item or link that forgets
    /// `stationAccessibilityScope()` fails here too.
    @MainActor
    private func assertNoStation(in app: XCUIApplication, named name: String) throws {
        let tree = app.debugDescription
        attachTree(tree, named: name)
        let identifiers = try captures(of: #"identifier: '(station\.[^']*)'"#, in: tree)
        XCTAssertTrue(identifiers.contains { $0.hasPrefix("station.tab.") || $0.hasPrefix("station.section.") },
                      "\(name): the sweep found none of the shell's own controls, so it proves nothing")
        let shellOwn = ["station.tab.", "station.section.", "station.devices.", "station.settings."]
        let leaked = identifiers.filter { identifier in !shellOwn.contains { identifier.hasPrefix($0) } }
        XCTAssertEqual(leaked, [], "\(name): the hidden station is in the accessibility tree")
        let sensitive = ["microphone", "destination", "talk", "privacy", "private", "listening", "recording"]
        let spoken = try captures(of: #"label: '([^']*)'"#, in: tree).filter { label in
            sensitive.contains { label.lowercased().contains($0) }
        }
        XCTAssertEqual(spoken, [], "\(name): the hidden station's wording is in the accessibility tree")
    }

    private func captures(of pattern: String, in text: String) throws -> [String] {
        let regex = try NSRegularExpression(pattern: pattern)
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            Range(match.range(at: 1), in: text).map { String(text[$0]) }
        }
    }

    @MainActor
    private func waitUntilHittable(_ element: XCUIElement, in app: XCUIApplication, named name: String) {
        let shown = XCTNSPredicateExpectation(predicate: NSPredicate(format: "isHittable == true"), object: element)
        if XCTWaiter().wait(for: [shown], timeout: 5) != .completed { attachTree(of: app, named: name) }
        XCTAssertTrue(element.isHittable, "\(name): not reachable after the station showed again")
    }

    /// The whole accessibility tree, kept with the result, so a failure shows what VoiceOver would have.
    @MainActor
    private func attachTree(of app: XCUIApplication, named name: String) {
        attachTree(app.debugDescription, named: name)
    }

    private func attachTree(_ tree: String, named name: String) {
        let attachment = XCTAttachment(string: tree)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Taps one of the station's own tool links, and waits for what it opens.
    @MainActor
    private func openStationTool(_ name: String, in app: XCUIApplication, opens title: XCUIElement) {
        let tool = app.buttons[name]
        // Hittable, and clear of the bottom edge, where the build footer sits over the scrolling station.
        let limit = app.windows.firstMatch.frame.maxY - 160
        for _ in 0..<6 where !(tool.exists && tool.isHittable && tool.frame.maxY < limit) { app.swipeUp() }
        XCTAssertTrue(tool.isHittable, "\(name) is reachable from the station tools")
        // A tap while a swipe still scrolls only stops the scroll, so tap again if the tool didn't open.
        tool.tap()
        if !title.waitForExistence(timeout: 3), tool.exists, tool.isHittable { tool.tap() }
        XCTAssertTrue(title.waitForExistence(timeout: 5), "\(name) opens")
    }

    @MainActor
    private func turnOnShellInLabs(_ app: XCUIApplication) {
        openStationTool("Labs", in: app, opens: app.navigationBars["Labs"])

        let toggle = app.switches["station.redesign.shell"]
        for _ in 0..<4 where !(toggle.exists && toggle.isHittable) { app.swipeUp() }
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(toggle.value as? String, "0", "Off by default")
        // The switch itself sits at the trailing edge; a tap on the row's label does not flip it.
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        XCTAssertEqual(toggle.value as? String, "1")
        XCTAssertTrue(app.staticTexts["station.redesign.shell.pending"].exists, "The row says a relaunch applies it")

        app.navigationBars.buttons.element(boundBy: 0).tap()
    }

    /// A tab on iPhone, a sidebar row on iPad. The row's icon carries its identifier too but isn't hittable, so
    /// the row is found by its title.
    @MainActor
    private func section(_ name: String, in app: XCUIApplication, isPad: Bool) -> XCUIElement {
        isPad ? app.staticTexts["station.section.\(name)"].firstMatch : app.buttons["station.tab.\(name)"].firstMatch
    }
}
