#if STATION_UI_FIXTURES && os(iOS)
import XCTest

extension ShellWindowStationStateScreenshotTests {
    @MainActor
    func testDockAndTabBarEdgesInCompactStation() throws {
        let arguments = ["-seed-navigation-shell", "-seed-station-state", "ready", "-measure-station-insets"]
        for legacy in [true, false] {
            let app = launchStation(arguments: arguments + (legacy ? ["-fixture-empty-dock-inset"] : []),
                                    ipadPortrait: true)
            let window = stationWindow(in: app)
            let tabBar = window.tabBars.containing(.button, identifier: "station.tab.settings").firstMatch
            let dock = element("station.voice-dock", in: window)
            // Measure the native scroll viewport that actually contains Talk.
            let viewports = window.scrollViews.containing(.button, identifier: "station.talk")
            let scroll = viewports.element
            let control = element("station.talk", in: window)
            for item in [tabBar, dock, scroll, control] {
                XCTAssertTrue(item.waitForExistence(timeout: 8))
                XCTAssertFalse(item.frame.isEmpty)
            }
            XCTAssertEqual(viewports.count, 1)
            let safeArea = element("fixture.bottom-inset", in: window)
            let value = try XCTUnwrap(safeArea.value as? String)
            let safeBottom = CGFloat(try XCTUnwrap(Double(value)))
            let gap = tabBar.frame.minY - dock.frame.maxY
            let belowBar = window.frame.maxY - tabBar.frame.maxY
            let name = legacy ? "compact-empty-inset" : "compact-dock"
            let metrics = XCTAttachment(string: """
                window=\(window.frame) safeBottom=\(safeBottom) bar=\(tabBar.frame)
                scroll=\(scroll.frame) dock=\(dock.frame) talk=\(control.frame)
                dockToTab=\(gap) belowBar=\(belowBar)
                """)
            metrics.name = "\(device)-\(name)-points"
            metrics.lifetime = .keepAlways
            add(metrics)
            attachScreen(name, in: app)
            if !legacy {
                XCTAssertEqual(gap, 0, accuracy: 2)
                XCTAssertEqual(scroll.frame.maxY, dock.frame.maxY, accuracy: 2)
                XCTAssertEqual(tabBar.frame.minY - control.frame.maxY, 8, accuracy: 3)
                XCTAssertEqual(belowBar, safeBottom, accuracy: 2)
            }
            app.terminate()
        }
    }
}
#endif
