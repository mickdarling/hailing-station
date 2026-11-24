import Testing

struct StationUIFixtureConfigurationTests {
    @Test func unitTestBuildExcludesStationUIFixtures() {
        #if STATION_UI_FIXTURES
        let enabled = true
        #else
        let enabled = false
        #endif
        #expect(!enabled)
    }
}
