#if os(macOS)
import Darwin
import Foundation
import HailProtocol
import Synchronization
@testable import HailDaemonKit

struct GuardSocketContext {
    let rig: SilentUpdateRig
    let endpoint: LocalReplyEndpoint
    let publisher: GuardTestPublisher
    let directory: URL
    var socket: String { directory.appendingPathComponent("c/replies.sock").path }
    func history() throws -> [String] { try fullHistory().filter { $0.contains("local-update") } }
    func fullHistory() throws -> [String] {
        do {
            return try AuditHistory(directory: directory.appendingPathComponent("audit")).today()
        } catch AuditHistoryError.noHistory {
            return []
        }
    }
}

func withGuardSocket(_ body: (GuardSocketContext) async throws -> Void) async throws {
    let rig = try await SilentUpdateRig.make()
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("hs-rg-\(UUID().uuidString.prefix(8))")
    defer { try? FileManager.default.removeItem(at: directory) }
    let publisher = GuardTestPublisher(listener: rig.listener)
    let endpoint = try LocalReplyEndpoint(socketURL: directory.appendingPathComponent("c/replies.sock"),
        destination: publisher, audit: AuditLog(directory: directory.appendingPathComponent("audit")))
    do {
        try await endpoint.start()
        try await body(.init(rig: rig, endpoint: endpoint, publisher: publisher, directory: directory))
    } catch {
        await endpoint.stop()
        await rig.listener.stop()
        throw error
    }
    await endpoint.stop()
    await rig.listener.stop()
}

final class GuardTestPublisher: HostReplyPublishing {
    let listener: WebSocketListener
    let calls = Mutex(0)
    init(listener: WebSocketListener) { self.listener = listener }
    func publish(_ frame: Frame) async throws -> Int { 1 }
    func sessionUpdate(_ request: LocalSessionUpdateRequest) async -> LocalSessionUpdateReport {
        calls.withLock { $0 += 1 }
        return await listener.sessionUpdate(request)
    }
}

/// Serial socket tests capture the actual content-free stderr lines.
final class GuardLogCapture {
    let url: URL
    let handle: FileHandle
    var original: Int32
    init(directory: URL) throws {
        url = directory.appendingPathComponent("refusals.log")
        _ = FileManager.default.createFile(atPath: url.path, contents: nil)
        handle = try FileHandle(forWritingTo: url)
        original = dup(STDERR_FILENO)
        _ = dup2(handle.fileDescriptor, STDERR_FILENO)
    }
    func restore() {
        guard original >= 0 else { return }
        _ = dup2(original, STDERR_FILENO)
        close(original)
        original = -1
        try? handle.close()
    }
    func lines() throws -> [String] {
        try String(contentsOf: url, encoding: .utf8).split(separator: "\n").map(String.init)
            .filter { $0.hasPrefix("session_update_refused ") }
    }
    deinit { restore() }
}
#endif
