import Darwin
import Foundation
import Testing
@testable import haild

/// Only this authored test process changes its own dispositions; no signal is delivered.
@Suite(.serialized) @MainActor struct CoachingKeyboardSignalTests {
    @Test(arguments: [false, true])
    func closeAndReleaseRestoreCompletePriorSignalDispositions(release: Bool) throws {
        let numbers = [SIGINT, SIGTERM]
        let original = try numbers.map { try snapshot($0) }
        defer {
            for (number, value) in zip(numbers, original) {
                var saved = value
                _ = sigaction(number, &saved, nil)
            }
        }
        for number in numbers {
            var desired = sigaction()
            desired.__sigaction_u.__sa_handler = SIG_DFL
            desired.sa_flags = SA_RESTART
            sigemptyset(&desired.sa_mask)
            sigaddset(&desired.sa_mask, SIGUSR1)
            try #require(sigaction(number, &desired, nil) == 0)
        }
        let expected = try numbers.map { try snapshot($0) }
        var ends: [Int32] = [-1, -1]
        try #require(pipe(&ends) == 0)
        defer { Darwin.close(ends[0]); Darwin.close(ends[1]) }
        var keyboard: CoachingKeyboard? = try CoachingKeyboard(input: ends[0], ended: {})
        if release { keyboard = nil } else { keyboard?.close() }
        for (number, prior) in zip(numbers, expected) {
            let restored = try snapshot(number)
            #expect(unsafeBitCast(restored.__sigaction_u.__sa_handler, to: UInt.self)
                == unsafeBitCast(prior.__sigaction_u.__sa_handler, to: UInt.self))
            #expect(restored.sa_flags == prior.sa_flags && restored.sa_mask == prior.sa_mask)
        }
        keyboard = nil
    }

    private func snapshot(_ number: Int32) throws -> sigaction {
        var value = sigaction()
        try #require(sigaction(number, nil, &value) == 0)
        return value
    }
}
