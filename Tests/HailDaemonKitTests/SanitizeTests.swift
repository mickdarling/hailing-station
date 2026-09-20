import Testing
@testable import HailDaemonKit

/// One row per attack class from #44 and the threat model's B3 tampering rows.
@Suite struct SanitizeTests {
    struct Row: Sendable {
        var name: String
        var input: String
        var expect: Result<[String], SanitizeError>
        var policy = SanitizePolicy()
    }

    @Test(arguments: rows.map(\.name))
    func row(named name: String) throws {
        let row = try #require(Self.rows.first { $0.name == name })
        let actual: Result<[String], SanitizeError>
        do {
            actual = .success(try Sanitizer.sanitize(row.input, policy: row.policy))
        } catch let error as SanitizeError {
            actual = .failure(error)
        }
        #expect(actual == row.expect, "\(name)")
    }

    @Test func rowNamesAreUnique() {
        #expect(Set(Self.rows.map(\.name)).count == Self.rows.count)
    }

    @Test func characterCapCountsGraphemesAndByteCapBoundsThem() throws {
        let emoji = String(repeating: "👨‍👩‍👧", count: 400)   // 400 characters, 7,200 bytes
        #expect(try Sanitizer.sanitize(emoji) == [emoji])
        let tooMany = String(repeating: "👨‍👩‍👧", count: 2_000)   // 2,000 characters, 36,000 bytes
        #expect(throws: SanitizeError.tooManyBytes(bytes: 36_000, limit: 8_192)) { try Sanitizer.sanitize(tooMany) }
    }
}
