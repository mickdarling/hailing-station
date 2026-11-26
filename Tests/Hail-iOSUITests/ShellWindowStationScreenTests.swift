import XCTest

final class ShellWindowStationScreenTests: XCTestCase, ShellWindowUITestSupport {
    override func setUpWithError() throws {
        continueAfterFailure = false
        #if os(iOS) && !targetEnvironment(simulator)
        throw XCTSkip("Station window qualification requires the simulator.")
        #endif
    }

    @MainActor
    func testOnboarding() {
        let app = launchStation(shellEnabled: true)
        captureBoth("onboarding", marker: "station.setup-mac", in: app)
        XCTAssertFalse(element("station.voice-dock.talk", in: app).isEnabled)
    }

    @MainActor
    func testFlagOffStation() {
        let app = launchStation(shellEnabled: false)
        XCTAssertFalse(element("station.listening-privacy-rail", in: app).exists)
        XCTAssertFalse(section("settings", in: app).exists)
        captureBoth("off", marker: "station.connection", in: app)
    }
}

#if STATION_UI_FIXTURES
@MainActor
extension ShellWindowStationScreenTests {
    func testSessionsDetailFollowsConfirmedDestination() {
        let app = launchStation(shellEnabled: true, arguments: ["-seed-station-screen", "destinations"])
        choose("sessions", in: app)
        let list = element("shell.sessions.list", in: stationWindow(in: app))
        let studio = sessionRow("ui-test-seed", in: list)
        let annex = sessionRow("annex", in: list)
        for (row, host) in [(studio, "Studio Mac"), (annex, "Annex Mac")] {
            waitUntilHittable(row)
            for detail in ["Workbench", host, "Terminal", "Online"] { assertRow(row, contains: detail) }
            assertRow(row, excludes: "Selected")
            if device != "iphone" { XCTAssertGreaterThan(row.frame.minX, section("sessions", in: app).frame.maxX) }
        }
        let rows = list.buttons.matching(NSPredicate(format: "identifier BEGINSWITH %@", "shell.sessions.row."))
        XCTAssertEqual(rows.count, 2)
        XCTAssertFalse(element("shell.sessions.placeholder", in: app).exists)

        activate(annex)
        assertRow(annex, contains: "Selected")
        assertRow(studio, excludes: "Selected")
        assertSidebar("Annex Mac", in: app)
        choose("station", in: app)
        let picker = destinationPicker(in: app)
        assertConfirmed(host: "Annex Mac", on: picker)
        activate(picker)
        activate(element("Studio Mac · Workbench", in: app))
        assertConfirmed(host: "Studio Mac", on: picker)
        choose("sessions", in: app)
        assertRow(studio, contains: "Selected")
        assertRow(annex, excludes: "Selected")
        assertSidebar("Studio Mac", in: app)
    }

    func testSessionsDetailShowsLastMessageOnlyOnItsHost() {
        let app = launchStation(shellEnabled: true, arguments: ["-seed-station-screen", "destinations",
                                                                "-seed-conversation", "4"])
        let picker = destinationPicker(in: app)
        XCTAssertTrue(element("station.choose-destination", in: app).waitForExistence(timeout: 8))
        activate(picker)
        activate(element("Studio Mac · Workbench", in: app))
        assertConfirmed(host: "Studio Mac", on: picker)
        choose("sessions", in: app)
        let list = element("shell.sessions.list", in: stationWindow(in: app))
        let studio = sessionRow("ui-test-seed", in: list)
        let annex = sessionRow("annex", in: list)
        assertRow(studio, contains: "Turn 4.")
        activate(annex)
        assertRow(annex, contains: "Selected")
        assertRow(studio, contains: "Last message · Today")
        assertRow(studio, contains: "Turn 4.")
        assertRow(annex, excludes: "Last message")
        assertRow(annex, excludes: "Turn 4.")
    }

    func testSessionsDetailExplainsEmptyList() {
        let app = launchStation(shellEnabled: true)
        choose("sessions", in: app)
        let window = stationWindow(in: app)
        waitUntilHittable(element("shell.sessions.placeholder", in: window))
        let help = window.descendants(matching: .any).matching(
            containingText("Sessions appear when a connected Mac has a live target.")
        ).firstMatch
        waitUntilHittable(help)
        if device != "iphone" { XCTAssertGreaterThan(help.frame.minX, section("sessions", in: app).frame.maxX) }
        XCTAssertFalse(element("shell.sessions.list", in: window).exists)
    }

    private func assertConfirmed(host: String, on picker: XCUIElement) {
        let confirmed = NSPredicate(format: "value == %@", "Destination: Mac \(host), Terminal Workbench.")
        let changed = XCTNSPredicateExpectation(predicate: confirmed, object: picker)
        XCTAssertEqual(XCTWaiter.wait(for: [changed], timeout: 8), .completed)
    }

    private func sessionRow(_ hostID: String, in list: XCUIElement) -> XCUIElement {
        list.buttons["shell.sessions.row.\(hostID)|tmux:ui-test-seed"]
    }

    private func assertSidebar(_ host: String, in app: XCUIApplication) {
        guard device != "iphone" else { return }
        let window = stationWindow(in: app)
        let sidebar = window.descendants(matching: .any).matching(containingText("Selected · \(host)")).firstMatch
        waitUntilHittable(sidebar)
        XCTAssertLessThan(sidebar.frame.midX, element("shell.sessions.list", in: window).frame.minX)
    }

    private func containingText(_ text: String) -> NSPredicate {
        NSPredicate(format: "label CONTAINS %@ OR title CONTAINS %@ OR value CONTAINS %@", text, text, text)
    }

    private func assertRow(_ row: XCUIElement, contains text: String) {
        let expectation = XCTNSPredicateExpectation(predicate: containingText(text), object: row)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 8), .completed, text)
    }

    private func assertRow(_ row: XCUIElement, excludes text: String) {
        XCTAssertTrue(row.exists)
        XCTAssertFalse(containingText(text).evaluate(with: row), text)
    }
}
#endif
