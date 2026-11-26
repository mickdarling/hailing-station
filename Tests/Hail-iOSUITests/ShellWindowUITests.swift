import XCTest

/// Launch and drive the actual flag-on station window (#1339).
final class ShellWindowUITests: XCTestCase {
    override func setUpWithError() throws {
        continueAfterFailure = false
        #if os(iOS)
        try XCTSkipUnless(ProcessInfo.processInfo.environment["SIMULATOR_UDID"] != nil,
                          "Shell qualification uses the iPhone and iPad simulators.")
        #endif
    }
}
