import Foundation
import Testing
@testable import HailProtocol
import HailProtocolFixtures

/// Every checked-in fixture must decode, re-encode byte for byte, and equal the in-code example (#2, #28).
@Suite struct FixtureConformanceTests {
    @Test(arguments: Fixtures.all.map(\.name))
    func fixtureMatchesInCodeExample(name: String) throws {
        let example = try #require(Fixtures.all.first { $0.name == name })
        let onDisk = try Fixtures.data(for: name)
        let decoded = try FrameCoding.decode(onDisk)
        #expect(decoded == example.frame)
        let reencoded = try FrameCoding.encode(decoded) + Data([0x0A])
        #expect(reencoded == onDisk, "fixture \(name) drifted; run hail-protocol-gen")
    }

    @Test func everyFrameTypeHasAFixture() {
        let covered = Set(Fixtures.all.compactMap { $0.frame.payload.type })
        #expect(covered == Set(FrameType.allCases))
        #expect(Fixtures.all.contains { if case .unknown = $0.frame.payload { true } else { false } })
    }

    @Test func fixtureNamesAreUnique() {
        #expect(Set(Fixtures.all.map(\.name)).count == Fixtures.all.count)
    }

    @Test func filesOnDiskMatchInCodeExamplesExactly() {
        #expect(Fixtures.namesOnDisk() == Set(Fixtures.all.map(\.name)), "stale or missing fixture file")
    }

    @Test func everyControlCommandHasAFixture() {
        let expected: Set<String> = [
            "hello", "listTargets", "targets", "select", "subscribe", "unsubscribe", "escape", "ping", "pong",
            "error"
        ]
        #expect(Fixtures.controlCommandsCovered == expected)
    }
}
