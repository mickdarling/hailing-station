import Testing

@Suite struct TestTimingTests {
    @Test func parsesEnvironmentWithoutReadingTheHost() {
        #expect(TestTiming.factor(environment: [:]) == 1)
        #expect(TestTiming.factor(environment: ["CI": "false"]) == 1)
        #expect(TestTiming.factor(environment: ["CI": "true"]) == 3)
        #expect(TestTiming.factor(environment: ["HAIL_CI_TIME_SCALE": "0.5"]) == 0.5)
        #expect(TestTiming.factor(environment: ["CI": "true", "HAIL_CI_TIME_SCALE": "2.5"]) == 2.5)
        for invalid in ["", "garbage", "0", "-1", "nan", "inf", "1e999"] {
            #expect(TestTiming.factor(environment: ["HAIL_CI_TIME_SCALE": invalid]) == 1)
            #expect(TestTiming.factor(environment: ["CI": "true", "HAIL_CI_TIME_SCALE": invalid]) == 3)
        }
    }
}
