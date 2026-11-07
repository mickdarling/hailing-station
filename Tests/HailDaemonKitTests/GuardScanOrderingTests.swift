import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit

/// Exhausted sequences repeat their last sample. Recovery samples expose a missing timeout latch.
private final class GuardClockSequence: Sendable {
    let wall: [Duration]
    let cpu: [Duration?]
    let reads = Mutex((wall: 0, cpu: 0))

    init(wall: [Duration] = [.zero], cpu: [Duration?] = [.zero]) {
        self.wall = wall
        self.cpu = cpu
    }

    var clock: GuardBudgetClock {
        let base = ContinuousClock.now
        return GuardBudgetClock(now: {
            let index = self.reads.withLock { reads in defer { reads.wall += 1 }; return reads.wall }
            return base + self.wall[min(index, self.wall.count - 1)]
        }, cpuNow: {
            let index = self.reads.withLock { reads in defer { reads.cpu += 1 }; return reads.cpu }
            return self.cpu[min(index, self.cpu.count - 1)]
        })
    }

    static func expiringAfterEntry(onCPUClock: Bool) -> GuardClockSequence {
        GuardClockSequence(wall: onCPUClock ? [.zero] : [.zero, .zero, .seconds(1), .zero],
                           cpu: onCPUClock ? [.zero, .zero, .milliseconds(20), .zero] : [.zero])
    }
}

extension GuardBudgetClockTests {
    @Test(arguments: [true, false], [true, false])
    func aClockDecreaseLatchesTimeout(onCPUClock: Bool, belowStart: Bool) throws {
        let samples: [Duration] = [.milliseconds(10), .milliseconds(12),
                                   .milliseconds(belowStart ? 9 : 11), .milliseconds(13)]
        let sequence = GuardClockSequence(wall: onCPUClock ? [.zero] : samples,
                                          cpu: onCPUClock ? samples.map { $0 } : [.zero])
        let guards = try CompiledGuards([GuardPattern(name: "rule", regex: "^sudo$")])
        let driver: @Sendable (NSRegularExpression, String, (Bool) -> Bool) -> Void = { regex, line, callback in
            #expect(sequence.reads.withLock { $0.cpu } == 2, "start and entry are within budget")
            #expect(regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil)
            #expect(callback(true), "the result callback must stop on a regressing sample")
            #expect(sequence.reads.withLock { $0.cpu } == 3)
        }
        GuardBudgetClock.$current.withValue(sequence.clock) {
            GuardMatchDriver.$enumerate.withValue(driver) {
                #expect(guards.hits(in: ["sudo"]) == [GuardHit(name: "rule", outcome: .timeout)])
            }
        }
        #expect(sequence.reads.withLock { $0.cpu == 3 && $0.wall == 3 },
                "the final check must keep the latch without reading the recovery sample")
    }

    @Test func aNilCPUSampleMidScanLatchesTimeout() throws {
        let sequence = GuardClockSequence(cpu: [.milliseconds(10), .milliseconds(12), nil, .milliseconds(13)])
        let guards = try CompiledGuards([GuardPattern(name: "rule", regex: "^sudo$")])
        let driver: @Sendable (NSRegularExpression, String, (Bool) -> Bool) -> Void = { regex, line, callback in
            #expect(sequence.reads.withLock { $0.cpu } == 2, "the matcher was entered")
            #expect(regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil)
            #expect(callback(true))
        }
        GuardBudgetClock.$current.withValue(sequence.clock) {
            GuardMatchDriver.$enumerate.withValue(driver) {
                #expect(guards.hits(in: ["sudo"]) == [GuardHit(name: "rule", outcome: .timeout)])
            }
        }
        #expect(sequence.reads.withLock { $0.cpu == 3 && $0.wall == 2 },
                "an unreadable CPU sample stays timed out through the final check")
    }
}

extension DangerousPatternTests {
    @Test(arguments: [true, false])
    func expiryAtAMatchingResultCallbackWins(onCPUClock: Bool) throws {
        let sequence = GuardClockSequence.expiringAfterEntry(onCPUClock: onCPUClock)
        let guards = try CompiledGuards([GuardPattern(name: "sudo", regex: "^sudo$")])
        let driver: @Sendable (NSRegularExpression, String, (Bool) -> Bool) -> Void = { regex, line, callback in
            #expect(sequence.reads.withLock { $0.cpu == 2 && $0.wall == 2 },
                    "entry passed before matching starts")
            #expect(regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil)
            #expect(callback(true), "expiry wins over the proven match at this callback")
            #expect(sequence.reads.withLock { $0.cpu == 3 && $0.wall == 3 },
                    "the expiry sample was consumed inside the result callback, before the final check")
        }
        GuardBudgetClock.$current.withValue(sequence.clock) {
            GuardMatchDriver.$enumerate.withValue(driver) {
                #expect(guards.hits(in: ["sudo"]) == [GuardHit(name: "sudo", outcome: .timeout)])
            }
        }
        #expect(sequence.reads.withLock { $0.cpu == 3 && $0.wall == 3 })
    }

    @Test(arguments: [true, false])
    func callbackFreeNoMatchExpiresAtTheFinalCheck(onCPUClock: Bool) throws {
        let sequence = GuardClockSequence.expiringAfterEntry(onCPUClock: onCPUClock)
        let guards = try CompiledGuards([GuardPattern(name: "sudo", regex: "^sudo$")])
        let driver: @Sendable (NSRegularExpression, String, (Bool) -> Bool) -> Void = { regex, line, _ in
            #expect(sequence.reads.withLock { $0.cpu == 2 && $0.wall == 2 })
            #expect(regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) == nil)
            // No callback: the next sample can only be consumed by boundedMatch's final check.
        }
        GuardBudgetClock.$current.withValue(sequence.clock) {
            GuardMatchDriver.$enumerate.withValue(driver) {
                #expect(guards.hits(in: ["echo"]) == [GuardHit(name: "sudo", outcome: .timeout)])
            }
        }
        #expect(sequence.reads.withLock { $0.cpu == 3 && $0.wall == 3 })
    }

    @Test(arguments: [true, false])
    func aLaterMatchingCandidateCannotReplaceTimeout(onCPUClock: Bool) throws {
        let sequence = GuardClockSequence.expiringAfterEntry(onCPUClock: onCPUClock)
        let guards = try CompiledGuards([GuardPattern(name: "sudo", regex: "^sudo$")])
        let visited = Mutex<[String]>([])
        let driver: @Sendable (NSRegularExpression, String, (Bool) -> Bool) -> Void = { regex, line, callback in
            visited.withLock { $0.append(line) }
            if regex.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                _ = callback(true)
            }
        }
        GuardBudgetClock.$current.withValue(.frozen) {
            #expect(guards.hits(in: ["sudo"]) == [GuardHit(name: "sudo", outcome: .match)])
        }
        GuardBudgetClock.$current.withValue(sequence.clock) {
            GuardMatchDriver.$enumerate.withValue(driver) {
                #expect(guards.hits(in: ["echo", "sudo"]) == [GuardHit(name: "sudo", outcome: .timeout)])
            }
        }
        #expect(visited.withLock { $0 } == ["echo"], "neither the later matching line nor the joined form runs")
        #expect(sequence.reads.withLock { $0.cpu == 3 && $0.wall == 3 })
    }
}
