import Foundation
import Testing

// Fixture scheduling watchdog; protocol deadlines use injected clocks and separate assertions. The condition is
// always checked once more after the deadline, so a wait whose condition came true during a stall still passes. A
// timeout records how the wait went (#704): its polls, when the first ran, and the longest gap between two. A gap
// near the timeout means the waiter itself was not scheduled; many polls with short gaps mean the condition never
// came true.
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
    while true {
        let now = clock.now
        firstPoll = firstPoll ?? now - start
        longestGap = max(longestGap, now - lastPoll)
        (polls, lastPoll) = (polls + 1, now)
        if try await condition() { return }
        if clock.now >= deadline { break }
        try await Task.sleep(for: .milliseconds(5))
    }
    Issue.record(Comment(rawValue: "waitUntil gave up at \(file):\(line) after \(polls) polls in "
        + "\(clock.now - start); first poll after \(firstPoll ?? .zero), longest gap \(longestGap)"))
    throw SocketTestError.conditionTimedOut(file: file, line: line)
}
