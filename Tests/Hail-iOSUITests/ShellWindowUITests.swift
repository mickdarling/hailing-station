import XCTest

/// Launch and drive the actual flag-on station window (#1339).
final class ShellWindowUITests: XCTestCase, ShellWindowUITestSupport {
    override func setUpWithError() throws {
        continueAfterFailure = false
        #if os(iOS)
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SIMULATOR_UDID"] != nil,
                          "Shell qualification uses the iPhone and iPad simulators.")
        #endif
    }

    @MainActor
    func testStationControlsOpenDestinationPickerAndDevices() {
        let app = launchStation(shellEnabled: true)
        let picker = destinationPicker(in: app)
        #if os(macOS)
        picker.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        #else
        activate(picker)
        #endif
        let prompt = "Choose a Mac, then the target"
        let instructions = app.staticTexts.matching(
            NSPredicate(format: "label BEGINSWITH %@ OR value BEGINSWITH %@", prompt, prompt)
        ).firstMatch
        XCTAssertTrue(instructions.waitForExistence(timeout: 5), "The destination browser must open")
        attachScreen("station-destinations", in: app)
        activateButton("Done", in: app.buttons)
        XCTAssertTrue(instructions.waitForNonExistence(timeout: 5))
        screen("station.connection", named: "station-picker-dismissed", in: app)

        let setup = element("station.mac-setup-tool", in: app)
        reveal(setup, in: app)
        activate(setup)
        screen("station.devices.mac-setup", named: "devices-from-station-tools", in: app)
    }

    @MainActor
    func testSectionDetailsAndSettingsRows() {
        let app = launchStation(shellEnabled: true)
        screen("station.connection", named: "station", in: app)
        choose("sessions", in: app)
        screen("shell.sessions.placeholder", named: "sessions", in: app)
        choose("station", in: app)
        screen("station.connection", named: "station-restored", in: app)
        choose("devices", in: app)
        screen("station.devices.mac-setup", named: "devices", in: app)
        activate(element("station.devices.mac-setup", in: app))
        screen("station.devices.setup-page", named: "devices-mac-setup", in: app)
        waitUntilHittable(app.textFields.firstMatch)

        choose("settings", in: app)
        screen("station.settings.appearance", named: "settings", in: app)
        openSetting("station.settings.appearance", shows: "appearance.settings", named: "appearance", in: app)
        activateButton("Done", in: app.buttons)
        for (name, entry, page) in Self.settingsPages {
            openSetting(entry, shows: page, named: name, in: app)
            // Change section while a tool is pushed. Returning must open Settings at its root.
            choose("sessions", in: app)
            XCTAssertTrue(element("shell.sessions.placeholder", in: app).waitForExistence(timeout: 5))
            choose("settings", in: app)
        }
        openSetting("station.settings.labs", shows: "station.redesign.shell", named: "labs", in: app)
    }

    @MainActor
    func testSidebarRecoveryAndLabsOptOut() {
        let app = launchStation(shellEnabled: true)
        if device != "iphone" {
            toggleSidebar(in: app, visibleAfter: false)
            screen("station.connection", named: "station-sidebar-hidden", in: app)
            toggleSidebar(in: app, visibleAfter: true)
            screen("station.connection", named: "station-sidebar-restored", in: app)
        }
        choose("devices", in: app)
        activate(element("station.devices.mac-setup", in: app))
        screen("station.devices.setup-page", named: "devices-mac-setup", in: app)
        if device != "iphone" {
            toggleSidebar(in: app, visibleAfter: false)
            screen("station.devices.setup-page", named: "devices-setup-sidebar-hidden", in: app)
            #if os(macOS)
            app.menuBars.menuBarItems["View"].click()
            app.menuItems["Show Sidebar"].click()
            assertSidebar(in: app, visible: true)
            app.typeKey("s", modifierFlags: [.control, .command])
            assertSidebar(in: app, visible: false)
            #endif
            toggleSidebar(in: app, visibleAfter: true)
        }
        choose("settings", in: app)
        if device != "iphone" {
            toggleSidebar(in: app, visibleAfter: false)
            screen("station.settings.appearance", named: "settings-sidebar-hidden", in: app)
        }
        openSetting("station.settings.labs", shows: "station.redesign.shell", named: "labs", in: app)
        disableShell(in: app)
        app.terminate()
        app.launchArguments = baseArguments
        launchStation(app)
        screen("station.connection", named: "station-shell-off", in: app)
        XCTAssertFalse(section("settings", in: app).exists)
    }

    @MainActor
    private func disableShell(in app: XCUIApplication) {
        let toggle = shellToggle(in: app)
        XCTAssertTrue(toggle.waitForExistence(timeout: 5))
        XCTAssertEqual(String(describing: toggle.value ?? ""), "1")
        #if os(macOS)
        activate(toggle)
        #else
        toggle.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        #endif
        screen("station.redesign.shell.pending", named: "settings-labs-off", in: app)
        XCTAssertEqual(String(describing: toggle.value ?? ""), "0")
    }

    private static let settingsPages = [
        ("listening", "settings.listening.entry", "settings.listening.overview"),
        ("audio", "station.settings.audio", "settings.audio.overview"),
        ("privacy", "station.settings.privacy", "settings.privacy.page"),
        ("voices", "settings.voices.entry", "settings.voices.overview"),
        ("notifications", "settings.notifications.entry", "settings.notifications.page"),
        ("targets", "settings.targets.entry", "settings.targets.page"),
        ("advanced", "settings.advanced.entry", "settings.advanced.overview"),
        ("turn-taking", "station.settings.turn-taking", "station.segment-pause")
    ]

    @MainActor
    private func openSetting(_ entry: String, shows identifier: String, named name: String, in app: XCUIApplication) {
        let row = element(entry, in: app)
        reveal(row, in: app)
        activate(row)
        screen(identifier, named: "settings-\(name)", in: app)
    }

    @MainActor
    private func toggleSidebar(in app: XCUIApplication, visibleAfter: Bool) {
        #if os(macOS)
        // AppKit exposes the toolbar item and a nested button for the same physical control.
        let buttons = stationWindow(in: app).toolbars.buttons
        let identifier = "shell.sidebar.toggle"
        let toggles = buttons.matching(identifier: identifier)
        XCTAssertTrue(toggles.firstMatch.waitForExistence(timeout: 5))
        let controls = toggles.allElementsBoundByIndex.filter { !$0.buttons[identifier].firstMatch.exists }
        XCTAssertEqual(controls.count, 1, "The Station toolbar must have exactly one sidebar control")
        activateButton(identifier, in: buttons)
        #else
        activate(app.buttons["shell.sidebar.toggle"])
        #endif
        assertSidebar(in: app, visible: visibleAfter)
    }

    @MainActor
    private func assertSidebar(in app: XCUIApplication, visible: Bool) {
        let predicate = NSPredicate(format: visible ? "exists == true AND isHittable == true"
                                    : "exists == false OR isHittable == false")
        let changed = XCTNSPredicateExpectation(predicate: predicate, object: section("settings", in: app))
        XCTAssertEqual(XCTWaiter().wait(for: [changed], timeout: 5), .completed)
    }
}

extension ShellWindowUITests {
    @MainActor
    func testRedesignedConversationHasNoTextSizeControl() {
        let app = launchStation(shellEnabled: true, arguments: ["-seed-conversation", "1"])
        XCTAssertTrue(element("station.chat", in: app).waitForExistence(timeout: 8))
        XCTAssertTrue(element("station.chat-expand", in: app).exists)
        XCTAssertFalse(element("station.text-size", in: app).exists)
        XCTAssertFalse(app.buttons["Conversation text size"].firstMatch.exists)
    }
}
