import Testing
@testable import HailDaemonKit

@Suite struct DaemonInfoTests {
    @Test func bannerNamesVersionAndProtocol() {
        #expect(DaemonInfo.banner == "haild 0.1.0 protocol v1")
    }
}
