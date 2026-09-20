import Testing
@testable import HailDaemonKit

/// The values a read-back is made of: the confirmation hash and the spoken denial (#41 item 2).
@Suite struct ReadBackTests {
    let id = "tmux:claude-hail"

    @Test func theConfirmationHashIsLengthPrefixedAndDomainSeparated() {
        func hash(_ target: String, _ binding: String, _ device: String, _ lines: [String]) -> String {
            DeliveryRequest(target: target, binding: binding, lines: lines, device: device).confirmationHash
        }
        #expect(hash("a", "b", "c", ["ab", "c"]) != hash("a", "b", "c", ["a", "bc"]))
        #expect(hash("a", "b", "c", ["x"]) != hash("b", "a", "c", ["x"]))
        #expect(hash("ab", "", "c", ["x"]) != hash("a", "b", "c", ["x"]))
        #expect(hash("a", "b", "c", []) != hash("a", "b", "c", [""]))
        #expect(hash("a", "b", "c", ["x"]) == hash("a", "b", "c", ["x"]))
        let digest = hash("a", "b", "c", ["x"])
        let hexOnly = digest.allSatisfy { $0.isHexDigit }
        #expect(digest.count == 64)
        #expect(hexOnly)
    }

    @Test func denialsSpeakTheirReason() {
        #expect("\(Denial.lockdown)" == "the host is in lockdown")
        #expect("\(Denial.rebound(id))" == "target tmux:claude-hail changed since it was allowed; allow it again")
        #expect("\(Denial.locked(id))" == "target tmux:claude-hail is locked")
        #expect("\(Denial.rateLimited(retryAfter: .seconds(1)))" == "rate limit reached, retry in 1 second")
        #expect("\(Denial.rateLimited(retryAfter: .milliseconds(1500)))" == "rate limit reached, retry in 2 seconds")
        #expect("\(Denial.emptyRequest)" == "delivery contains no lines")
        #expect("\(Denial.unbound(id))" == "target tmux:claude-hail reported no binding, so it cannot be matched")
    }
}
