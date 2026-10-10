import Foundation
import Testing
@testable import HailDaemonKit

/// The daemon's status snapshot (#247): kept current from its own events, owner-only and replaced atomically.
@Suite final class DaemonStatusRecorderTests {
    private let directory: URL

    init() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("hail-status-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    deinit { try? FileManager.default.removeItem(at: directory) }

    private var file: URL { directory.appendingPathComponent("status.json") }

    private func recorder(
        pid: Int32 = 4242, running: @escaping @Sendable (Int32) -> Bool = { _ in true }
    ) -> DaemonStatusRecorder {
        DaemonStatusRecorder(file: file, hostID: "themachine.local", build: "aaaaaaaaaaaaaaaa", pid: pid,
                             now: { Date(timeIntervalSince1970: 1_000) }, isRunning: running)
    }

    @Test func aSecondInstanceLeavesALiveDaemonsSnapshotAlone() throws {
        recorder().observe(.init(event: "listener_ready", endpoint: "127.0.0.1:18765"))
        let second = recorder(pid: 5555, running: { $0 == 4242 })
        second.observe(.init(event: "listener_failed", detail: "Address already in use"))
        second.observe(.init(event: "listener_stopped", detail: "listener failed"))
        let status = try #require(DaemonStatus.read(from: file))
        #expect(status.pid == 4242 && status.listener.state == "ready")
    }

    @Test func aDeadOrStoppedDaemonsSnapshotIsReplaced() throws {
        recorder().observe(.init(event: "listener_ready", endpoint: "127.0.0.1:18765"))
        // The previous daemon's process is gone.
        let next = recorder(pid: 5555, running: { $0 == 5555 })
        #expect(try #require(DaemonStatus.read(from: file)).pid == 5555)
        // The previous daemon stopped cleanly, even if its pid is reused.
        next.observe(.init(event: "listener_stopped", detail: "SIGTERM"))
        _ = recorder(pid: 6666)
        #expect(try #require(DaemonStatus.read(from: file)).pid == 6666)
    }

    @Test func concurrentEventsLeaveTheLatestSnapshot() async throws {
        let recorder = recorder()
        await withTaskGroup(of: Void.self) { group in
            for _ in 0..<64 {
                group.addTask { recorder.observe(.init(event: "session_connected", sessionID: UUID())) }
            }
        }
        #expect(try #require(DaemonStatus.read(from: file)).connectedSessions == 64)
    }

    @Test func ambientEventsAreTrackedWithoutText() throws {
        let recorder = DaemonStatusRecorder(file: file, hostID: "themachine.local", build: nil, ambientEnabled: true,
                                            pid: 4242, now: { Date(timeIntervalSince1970: 2_000) })
        #expect(try #require(DaemonStatus.read(from: file)).ambient == .init(enabled: true))
        recorder.observe(.init(event: "ambient_started"))
        recorder.observe(.init(event: "ambient_started"))
        recorder.observe(.init(event: "ambient_ended", detail: "child transportLost"))
        recorder.observe(.init(event: "ambient_refused", detail: "stopping"))
        let status = try #require(DaemonStatus.read(from: file))
        let ambient = try #require(status.ambient)
        #expect(ambient.running == 1 && ambient.refusals == 1)
        #expect(ambient.lastEvent == "ambient_refused" && ambient.lastDetail == "stopping")
        #expect(ambient.lastEventAt == Date(timeIntervalSince1970: 2_000))
        recorder.observe(.init(event: "ambient_ended", detail: "delivered=1 written=2 dropped=0 echo=0 exit=exited(0)"))
        recorder.observe(.init(event: "ambient_ended", detail: "delivered=0 written=0 dropped=0 echo=0 exit=exited(0)"))
        #expect(try #require(DaemonStatus.read(from: file)).ambient?.running == 0)
    }

    @Test func anEndBeforeItsStartKeepsTheFailureVisible() throws {
        let recorder = DaemonStatusRecorder(file: file, hostID: "themachine.local", build: nil, ambientEnabled: true,
                                            pid: 4242)
        recorder.observe(.init(event: "ambient_ended", detail: "child transportLost"))
        recorder.observe(.init(event: "ambient_started"))
        let ambient = try #require(DaemonStatus.read(from: file)?.ambient)
        #expect(ambient.running == 0)
        #expect(ambient.lastEvent == "ambient_ended" && ambient.lastDetail == "child transportLost")
        recorder.observe(.init(event: "ambient_started"))
        #expect(try #require(DaemonStatus.read(from: file)?.ambient).running == 1)
    }

    /// #405: a child `haild ambient reload` replaced is counted out, but never hides a newer child's failure.
    @Test func aReplacedChildsEndCountsButNeverBecomesTheLastEvent() throws {
        let recorder = DaemonStatusRecorder(file: file, hostID: "themachine.local", build: nil, ambientEnabled: true,
                                            pid: 4242)
        recorder.observe(.init(event: "ambient_started"))
        recorder.observe(.init(event: "ambient_started"))
        recorder.observe(.init(event: "ambient_reloaded"))
        recorder.observe(.init(event: "ambient_ended", detail: "child transportLost"))
        recorder.observe(.init(event: "ambient_ended", detail: "replaced delivered=0 written=9 exit=signaled(15)"))
        let ambient = try #require(DaemonStatus.read(from: file)?.ambient)
        #expect(ambient.running == 0)
        #expect(ambient.lastEvent == "ambient_ended" && ambient.lastDetail == "child transportLost")
    }

    @Test func aSnapshotWithoutAmbientStillReads() throws {
        _ = recorder()
        var json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        json["ambient"] = nil
        try JSONSerialization.data(withJSONObject: json).write(to: file)
        #expect(try #require(DaemonStatus.read(from: file)).ambient == nil)
    }

    @Test func aMissingDirectoryIsNotAnError() {
        let missing = directory.appendingPathComponent("absent/status.json")
        let recorder = DaemonStatusRecorder(file: missing, hostID: "themachine.local", build: nil, pid: 1)
        recorder.observe(.init(event: "listener_ready", endpoint: "127.0.0.1:18765"))
        #expect(DaemonStatus.read(from: missing) == nil)
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
