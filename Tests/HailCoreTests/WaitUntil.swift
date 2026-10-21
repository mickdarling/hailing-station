import Foundation
import Testing
import HailTestSupport

// Fixture scheduling watchdog; protocol deadlines use injected clocks and separate assertions. A timeout records
// how the wait went (#704): its polls, the longest single condition check, and the longest overshoot of a 5 ms
// sleep. A long overshoot means the waiter itself was not scheduled; a long check means the condition waited on a
// busy actor. It also records whether the condition was true when checked once more after the deadline (for the
// record only: a late pass is still a timeout), and the scripted connector opens since the wait began, this test's
// and the whole process's: none for this test means its connection opening tasks never reached `connector.open`.
func waitUntil(
    timeout: Duration = .seconds(10),
    file: String = #fileID,
    line: Int = #line,
    _ condition: @escaping @Sendable () async throws -> Bool
) async throws {
    _ = StallWatchdog.started // #704: names what stalls the pool, on CI only
    let clock = ContinuousClock()
    let start = clock.now
    let deadline = start.advanced(by: timeout)
    var polls = 0, longestCheck = Duration.zero, longestOvershoot = Duration.zero
    while clock.now < deadline {
        let checked = clock.now
        if try await condition() { return }
        polls += 1
        longestCheck = max(longestCheck, clock.now - checked)
        let slept = clock.now
        try await Task.sleep(for: .milliseconds(5))
        longestOvershoot = max(longestOvershoot, clock.now - slept - .milliseconds(5))
    }
    let gaveUp = clock.now - start, lateStart = clock.now
    let late = (try? await condition()) ?? false
    let lateCheck = clock.now - lateStart
    Issue.record(Comment(rawValue: "waitUntil gave up at \(file):\(line) after \(polls) polls in \(gaveUp); "
        + "longest check \(longestCheck), longest sleep overshoot \(longestOvershoot); true after the deadline: "
        + "\(late) (checked in \(lateCheck)); connector opens since the wait began: "
        + ScriptedConnector.opens(since: start)))
    throw SocketTestError.conditionTimedOut(file: file, line: line)
}
