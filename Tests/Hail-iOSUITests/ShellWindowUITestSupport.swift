import XCTest
#if os(macOS)
import AppKit
#endif

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
        launchStation(app)
        XCTAssertTrue(section("station", in: app).waitForExistence(timeout: 10))
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
        let width = min(900, visible.width)
        let height = min(672, visible.height)
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

    func stationWindow(in app: XCUIApplication) -> XCUIElement {
        #if os(macOS)
        app.windows.matching(identifier: "station").firstMatch
        #else
        app.windows.firstMatch
        #endif
    }

    func stationContent(in app: XCUIApplication) -> XCUIElement {
        #if os(macOS)
        stationWindow(in: app).scrollViews.containing(.button, identifier: "station.destination").element
        #else
        app
        #endif
    }

    func destinationPicker(in app: XCUIApplication) -> XCUIElement {
        let content = stationContent(in: app)
        let picker = content.buttons["station.destination"].firstMatch
        waitUntilHittable(picker)
        #if os(macOS)
        XCTAssertTrue(content.exists, "The destination picker belongs to the Station detail")
        let center = CGPoint(x: picker.frame.midX, y: picker.frame.midY)
        XCTAssertTrue(content.frame.contains(center), "The picker must be visible inside the Station scroll view")
        #endif
        return picker
    }

    func element(_ identifier: String, in root: XCUIElement) -> XCUIElement {
        // Some SwiftUI labels identify both the text and the decorative image.
        let predicate = NSPredicate(format: "identifier == %@ AND elementType != %@",
                                    identifier, NSNumber(value: XCUIElement.ElementType.image.rawValue))
        return root.descendants(matching: .any).matching(predicate).firstMatch
    }

    func section(_ name: String, in app: XCUIApplication) -> XCUIElement {
        let prefix = device == "iphone" ? "station.tab." : "station.section."
        return element(prefix + name, in: stationWindow(in: app))
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
        let window = stationWindow(in: app)
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
        let window = stationWindow(in: app)
        #if os(macOS)
        let marker = identifier == "station.connection"
            ? stationContent(in: app).staticTexts[identifier]
            : element(identifier, in: app)
        #else
        let marker = element(identifier, in: app)
        #endif
        XCTAssertTrue(marker.waitForExistence(timeout: 10), identifier)
        switch identifier {
        case "station.connection":
            waitUntilHittable(marker)
            _ = destinationPicker(in: app)
            #if os(macOS)
            let footer = window.staticTexts["station.build-info"]
            XCTAssertTrue(footer.exists)
            XCTAssertFalse(footer.frame.intersects(marker.frame), "The footer must leave the connection badge exposed")
            #endif
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
        let attachment = XCTAttachment(screenshot: stationWindow(in: app).screenshot())
        attachment.name = "\(device)-\(name)"
        attachment.lifetime = .keepAlways
        add(attachment)
    }
}
