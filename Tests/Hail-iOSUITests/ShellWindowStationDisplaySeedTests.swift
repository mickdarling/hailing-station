#if STATION_UI_FIXTURES
import XCTest

final class ShellWindowStationDisplaySeedTests: XCTestCase {
    func testLaunchArgumentsRequireTheTestShell() {
        let flag = ["-seed-station-state", "listening"]
        let testApp = "com.mickdarling.Hail-macOS-shell-tests"
        XCTAssertNil(StationDisplaySeedLaunch.name(in: flag, bundleID: testApp, shellEnabled: true))
        let arguments = ["-reset-station-state", "-seed-navigation-shell"] + flag
        XCTAssertNil(StationDisplaySeedLaunch.name(in: arguments, bundleID: testApp, shellEnabled: false))
        XCTAssertNil(StationDisplaySeedLaunch.name(in: Array(arguments.dropFirst()), bundleID: testApp,
                                                   shellEnabled: true))
        XCTAssertEqual(StationDisplaySeedLaunch.name(in: arguments, bundleID: testApp, shellEnabled: true), "listening")
        #if os(macOS)
        XCTAssertNil(StationDisplaySeedLaunch.name(in: arguments, bundleID: "ordinary-app", shellEnabled: true))
        #endif
    }

    func testSnapshotsDistinguishPrivacyAcknowledgementAndManualCapture() {
        let pending = StationTranscriptSeed.pending
        XCTAssertTrue(pending.privacy.pending)
        XCTAssertFalse(pending.privacy.isPrivate)
        XCTAssertEqual(pending.rail(on: .mac).kind, .mayBeRecording)
        XCTAssertEqual(StationTranscriptSeed.private.rail(on: .mac).kind, .privateConfirmed)
        XCTAssertEqual(StationTranscriptSeed.private.rail(on: .mac).mic, .live)
        for state in StationTranscriptSeed.allCases {
            XCTAssertEqual(state.dock.showsCaption, state == .recording)
            XCTAssertEqual(state.dock.primary, state == .recording ? .finish : .talk)
        }
        for state: StationTranscriptSeed in [.listening, .media, .held] {
            XCTAssertEqual(state.listeningPhase, .listening)
            XCTAssertEqual(state.rail(on: .mac).mic, .live)
        }
        XCTAssertEqual(StationTranscriptSeed.handoff.rail(on: .mac).summary, "Listening on iPhone")
        XCTAssertEqual(StationTranscriptSeed.handoff.rail(on: .phone).mic, .off)
        XCTAssertEqual(StationTranscriptSeed.ready.rail(on: .mac).kind, .off)
    }
}
#endif
