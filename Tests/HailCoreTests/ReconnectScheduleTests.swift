import HailCore
import Testing

@Suite struct ReconnectScheduleTests {
    @Test func boundedExponentialDelaysAndJitterAreDeterministic() {
        let schedule = ReconnectSchedule()
        #expect((1...8).map { schedule.delay(attempt: $0, jitterUnit: 0.5) } == [1, 2, 4, 8, 16, 30, 30, 30])
        #expect(schedule.delay(attempt: 1, jitterUnit: 0) == 0.8)
        #expect(abs(schedule.delay(attempt: 1, jitterUnit: 1) - 1.2) < 0.000_001)
    }
}
