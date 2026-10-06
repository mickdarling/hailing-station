import Foundation
import Testing
@testable import HailDaemonKit

/// Build identity is the release digest prefix `scripts/host.sh` uses (#246, #247).
@Suite struct BuildIdentityTests {
    @Test func digestIsTheFirstSixteenHexOfSHA256() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("hail-build-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: file) }
        try Data("abc".utf8).write(to: file)
        #expect(BuildIdentity.digest(of: file) == "ba7816bf8f01cfea")
    }

    @Test func anUnreadableFileHasNoIdentity() {
        #expect(BuildIdentity.digest(of: URL(fileURLWithPath: "/nonexistent/haild")) == nil)
    }

    @Test func theTestRunnerHasAnIdentity() {
        #expect(BuildIdentity.current()?.count == 16)
    }
}
