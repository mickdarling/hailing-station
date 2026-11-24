import XCTest

@MainActor
extension ShellWindowUITests {
    var device: String {
        #if os(macOS)
        "mac"
        #else
        UIDevice.current.userInterfaceIdiom == .pad ? "ipad" : "iphone"
        #endif
    }

    var baseArguments: [String] {
        #if os(macOS)
        // The isolated window must never discover or connect to a configured local host.
        ["-hailing-station.local-host-offered.v1", "YES"]
        #else
        []
        #endif
    }

    func launchShell() -> XCUIApplication {
        #if os(macOS)
        let app = XCUIApplication(bundleIdentifier: "com.mickdarling.Hail-macOS-shell-tests")
        #else
        let app = XCUIApplication()
        if device == "ipad" { XCUIDevice.shared.orientation = .landscapeLeft }
        #endif
        let reset = baseArguments + ["-reset-station-state"]
        addTeardownBlock { @MainActor in
            app.terminate()
            app.launchArguments = reset
            app.launch()
            app.terminate()
            #if os(iOS)
            XCUIDevice.shared.orientation = .portrait
            #endif
        }
        app.launchArguments = reset + ["-seed-navigation-shell"]
        app.launch()
        XCTAssertTrue(section("station", in: app).waitForExistence(timeout: 10))
        return app
    }

    func element(_ identifier: String, in app: XCUIApplication) -> XCUIElement {
        // Some SwiftUI labels identify both the text and the decorative image.
        let predicate = NSPredicate(format: "identifier == %@ AND elementType != %@",
                                    identifier, NSNumber(value: XCUIElement.ElementType.image.rawValue))
        return app.descendants(matching: .any).matching(predicate).firstMatch
    }

    func section(_ name: String, in app: XCUIApplication) -> XCUIElement {
        let prefix = device == "iphone" ? "station.tab." : "station.section."
        return element(prefix + name, in: app)
    }

    func choose(_ name: String, in app: XCUIApplication) {
        activate(section(name, in: app))
    }

    func activate(_ item: XCUIElement) {
        XCTAssertTrue(item.waitForExistence(timeout: 5))
        waitUntilHittable(item)
        #if os(macOS)
        item.click()
        #else
        item.tap()
        #endif
    }

    func waitUntilHittable(_ item: XCUIElement) {
        XCTAssertTrue(item.wait(for: \.isHittable, toEqual: true, timeout: 5), item.debugDescription)
    }

    func activateButton(_ identifier: String, in query: XCUIElementQuery) {
        // AppKit can expose both a toolbar item and its inner button with the same identifier.
        let matches = query.matching(identifier: identifier)
        XCTAssertTrue(matches.firstMatch.waitForExistence(timeout: 5), identifier)
        guard let button = matches.allElementsBoundByIndex.first(where: {
            $0.wait(for: \.isHittable, toEqual: true, timeout: 5)
        }) else {
            XCTFail("No hittable button for \(identifier)")
            return
        }
        activate(button)
    }

    func reveal(_ row: XCUIElement, in app: XCUIApplication) {
        let window = app.windows.firstMatch
        for _ in 0..<6 where !row.exists || !row.isHittable {
            let start = window.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.7))
            #if os(macOS)
            start.scroll(byDeltaX: 0, deltaY: -140)
            #else
            let end = window.coordinate(withNormalizedOffset: CGVector(dx: 0.75, dy: 0.35))
            start.press(forDuration: 0.05, thenDragTo: end)
            #endif
        }
    }

    func screen(_ identifier: String, named name: String, in app: XCUIApplication) {
        let marker = element(identifier, in: app)
        XCTAssertTrue(marker.waitForExistence(timeout: 10), identifier)
        let window = app.windows.firstMatch
        switch identifier {
        case "station.connection":
            waitUntilHittable(marker)
            waitUntilHittable(app.buttons["station.destination"].firstMatch)
        case "shell.sessions.placeholder", "station.devices.mac-setup",
             "station.settings.appearance", "station.redesign.shell":
            waitUntilHittable(marker)
        default:
            break
        }
        let visible = marker.frame.intersection(window.frame)
        XCTAssertGreaterThan(visible.width, 0, identifier)
        XCTAssertGreaterThan(visible.height, 0, identifier)
        attachScreen(name, in: app)
    }

    func attachScreen(_ name: String, in app: XCUIApplication) {
        let attachment = XCTAttachment(screenshot: app.windows.firstMatch.screenshot())
        attachment.name = "\(device)-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
