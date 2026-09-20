import Testing
@testable import HailProtocol

@Suite struct ProtocolVersionTests {
    @Test func currentVersionIsOne() {
        #expect(ProtocolVersion.current == 1)
    }

    @Test func frameTypesRoundTripThroughRawValues() {
        for type in FrameType.allCases {
            #expect(FrameType(rawValue: type.rawValue) == type)
        }
    }
}
