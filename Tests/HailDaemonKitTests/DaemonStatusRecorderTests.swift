import Foundation
import Testing
@testable import HailDaemonKit

/// The daemon's status snapshot (#247): kept current from its own events, owner-only and replaced atomically.
@Suite struct DaemonStatusRecorderTests {
    private let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hail-status-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    private var file: URL { directory.appendingPathComponent("status.json") }

    private func recorder() -> DaemonStatusRecorder {
        DaemonStatusRecorder(file: file, hostID: "themachine.local", build: "aaaaaaaaaaaaaaaa", pid: 4242,
                             now: { Date(timeIntervalSince1970: 1_000) })
    }

    @Test func construction_writesAnOwnerOnlyStartingSnapshot() throws {
        _ = recorder()
        let status = try #require(DaemonStatus.read(from: file))
        #expect(status.listener.state == "starting")
        #expect(status.pid == 4242 && status.build == "aaaaaaaaaaaaaaaa" && status.hostID == "themachine.local")
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["status.json"])
    }

    @Test func listenerAndSessionEventsKeepTheSnapshotCurrent() throws {
        let recorder = recorder()
        let first = UUID()
        let second = UUID()
        recorder.observe(.init(event: "listener_ready", endpoint: "127.0.0.1:18765"))
        recorder.observe(.init(event: "session_connected", sessionID: first, endpoint: "peer"))
        recorder.observe(.init(event: "session_connected", sessionID: second, endpoint: "peer"))
        recorder.observe(.init(event: "session_connected", sessionID: first, endpoint: "peer"))
        var status = try #require(DaemonStatus.read(from: file))
        #expect(status.listener == .init(state: "ready", endpoint: "127.0.0.1:18765"))
        #expect(status.connectedSessions == 2)
        recorder.observe(.init(event: "session_disconnected", sessionID: first))
        status = try #require(DaemonStatus.read(from: file))
        #expect(status.connectedSessions == 1)
        recorder.observe(.init(event: "listener_stopped", detail: "SIGTERM"))
        status = try #require(DaemonStatus.read(from: file))
        #expect(status.listener == .init(state: "stopped", detail: "SIGTERM") && status.connectedSessions == 0)
    }

    @Test func peerAddressesNeverReachTheSnapshot() throws {
        let recorder = recorder()
        recorder.observe(.init(event: "session_connected", sessionID: UUID(), endpoint: "100.64.1.2:50000"))
        let text = try String(contentsOf: file, encoding: .utf8)
        #expect(!text.contains("100.64.1.2"))
    }

    @Test func failuresAndUnrelatedEventsAreHandled() throws {
        let recorder = recorder()
        recorder.observe(.init(event: "listener_failed", detail: "Address already in use"))
        recorder.observe(.init(event: "session_connected"))
        recorder.observe(.init(event: "ambient_started"))
        let status = try #require(DaemonStatus.read(from: file))
        #expect(status.listener == .init(state: "failed", detail: "Address already in use"))
        #expect(status.connectedSessions == 0)
    }

    @Test func anotherSchemaOrGarbageReadsAsNoSnapshot() throws {
        _ = recorder()
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        json["schema"] = DaemonStatus.currentSchema + 1
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        #expect(DaemonStatus.read(from: file) == nil)
        try Data("not json".utf8).write(to: file)
        #expect(DaemonStatus.read(from: file) == nil)
    }

    @Test func standardFileSitsBesideThePolicyFile() {
        let url = DaemonStatus.standardFile(environment: ["HAIL_CONFIG_DIR": "/tmp/hail-config"])
        #expect(url.path == "/tmp/hail-config/status.json")
    }
}
