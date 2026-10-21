import Foundation
import Testing

// Fixture scheduling watchdog; protocol deadlines use injected clocks and separate assertions. A timeout records
// how the wait went (#704): its polls, when the first ran, the longest gap between two, whether the condition was
// true when checked once more after the deadline, and the scripted connector opens anywhere in the process since the
// wait began. A gap near the timeout means the waiter was not scheduled; short gaps and no opens mean connection
// opening tasks never ran. The late check is for the record only: a late pass is still a timeout.
func waitUntil(
    timeout: Duration = .seconds(10),
    file: String = #fileID,
    line: Int = #line,
    _ condition: @escaping @Sendable () async throws -> Bool
) async throws {
    let clock = ContinuousClock()
    let start = clock.now
    let deadline = start.advanced(by: timeout)
    var polls = 0, firstPoll: Duration?, longestGap = Duration.zero, lastPoll = start
    while clock.now < deadline {
        let now = clock.now
        firstPoll = firstPoll ?? now - start
        longestGap = max(longestGap, now - lastPoll)
        (polls, lastPoll) = (polls + 1, now)
        if try await condition() { return }
        try await Task.sleep(for: .milliseconds(5))
    }
    let lateGap = clock.now - lastPoll
    let late = (try? await condition()) ?? false
    let opens = ScriptedConnector.opens(since: start)
    Issue.record(Comment(rawValue: "waitUntil gave up at \(file):\(line) after \(polls) polls in "
        + "\(clock.now - start); first poll after \(firstPoll ?? .zero), longest gap \(max(longestGap, lateGap)); "
        + "true after the deadline: \(late); connector opens since the wait began: \(opens)"))
    throw SocketTestError.conditionTimedOut(file: file, line: line)
}
