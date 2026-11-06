import Foundation
import Testing
@testable import HailDaemonKit

/// Deterministic conformance of the real fake-TUI plain() transitions, not another PTY delivery claim.
struct FakeTUIPlainReadReplay: Decodable {
    struct Scenario: Decodable {
        let pendingLong: String?
        let pendingDeadline: Double
        let shortReadAt: Double
        let submits: [String]
    }

    let beforeExpiry: Scenario
    let afterExpiry: Scenario

    static func run(long: String, short: String) async throws -> Self {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hs-tui-read-replay-\(UUID().uuidString)", isDirectory: true
        )
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: directory) }
        let result = try await ProcessCommandRunner().run(
            "python3", ["-c", script, long, short, directory.path]
        )
        try #require(result.exitCode == 0, "fake-TUI read replay: \(result.errorText)")
        return try JSONDecoder().decode(Self.self, from: Data(result.stdout.utf8))
    }

    private static let script = #"""
import json, os, sys
class Clock:
    value = 0.0
    def time(self): return self.value
time = Clock()
"""# + "\n" + FakeTUI.inputModel + "\n" + #"""
long, short, directory = sys.argv[1:]
def replay(at, name):
    global log
    log = os.path.join(directory, name)
    time.value = 0.0
    plain(long, False)
    pending_long = pending[1] if pending else None
    deadline = pending[2] if pending else -1
    time.value = at
    if at >= deadline: flush_pending()
    plain(short, False)
    plain("\r", False)
    with open(log) as f: submits = [json.loads(line)["text"] for line in f]
    return {"pendingLong": pending_long, "pendingDeadline": deadline,
            "shortReadAt": at, "submits": submits}
print(json.dumps({"beforeExpiry": replay(0.03, "before.jsonl"),
                  "afterExpiry": replay(0.101, "after.jsonl")}))
"""#
}
