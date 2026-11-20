import XCTest

extension AppearanceSettingsUITests {
    /// The native Mac fixture did not vary its numeric ScaledMetric under injected DynamicTypeSize. These actual
    /// iOS content-size-category launches retain a font-size sensitivity control instead of accepting equality alone.
    @MainActor
    func testTheWindowSheetPreservesSystemTextSizeDespiteDenseStationContent() {
        addTeardownBlock { @MainActor in XCUIDevice.shared.orientation = .portrait }
        XCUIDevice.shared.orientation = .portrait
        let large = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryL"]
        let normal = measureSheetPreview(extra: large, named: "appearance-scale-system-large")
        let dense = measureSheetPreview(extra: large + ["-appearance-dense-example"],
                                        named: "appearance-scale-dense-parent")
        XCTAssertEqual(dense.width, normal.width, accuracy: 0.5)
        XCTAssertEqual(dense.height, normal.height, accuracy: 0.5)

        let accessible = measureSheetPreview(extra: [
            "-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL",
            "-appearance-dense-example"
        ], named: "appearance-scale-system-accessibility-xxxl")
        XCTAssertGreaterThan(accessible.height, normal.height,
                             "The authored preview must respond to the real system category despite dense content.")
    }

    @MainActor
    private func measureSheetPreview(extra: [String], named name: String) -> CGRect {
        let app = launchEntryPreview(extra: extra)
        defer { app.terminate() }
        waitForOrientation(landscape: false, in: app)
        app.buttons["station.settings"].tap()
        assertValue("17 points, default", in: app)
        let text = element("appearance.preview.you", in: app)
        XCTAssertTrue(text.waitForExistence(timeout: 5))
        reveal(text, in: app)
        XCTAssertTrue(text.isHittable, "Measure the actual authored sentence after revealing it in the sheet.")
        let frame = text.frame
        XCTAssertGreaterThan(frame.width, 0)
        XCTAssertGreaterThan(frame.height, 0)
        attach(app, named: name)
        return frame
    }
}
