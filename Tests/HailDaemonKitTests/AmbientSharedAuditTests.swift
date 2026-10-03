#if os(macOS)
import Foundation
import HailProtocol
import Network
import Synchronization
import Testing
@testable import HailDaemonKit

/// #203 round 2: the daemon composes one `AuditLog` for the `--reply-to` socket and ambient dispatches, so
/// both are audited in the same day's file; two writers on one directory would lock one of them out.
@Suite(.serialized, .timeLimit(.minutes(1))) struct AmbientSharedAuditTests {
    // Composition, both ingress paths and the audit read stay in one scope, as in LocalReplyEndpointTests.
    // swiftlint:disable:next function_body_length
    @Test func ambientAndReplyToDispatchesAreBothAuditedInOneDaemonDay() async throws {
        // The daemon admits only live-microphone turns, so the fake stamps the fixture's turns as such.
        let fake = try FakeRightyo("""
            /usr/bin/wc -c > /dev/null
            /usr/bin/sed -e "s/tool-demo/$7/g" \
              -e 's/"provenance": "synthetic"/"provenance": "live-microphone"/g' events.jsonl
            """)
        defer { fake.cleanUp() }
        try fake.install(fixture: "tool-events.jsonl")
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("hs-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: scratch) }
        let socket = scratch.appendingPathComponent(LocalReplyEndpoint.socketName)
        let auditDirectory = scratch.appendingPathComponent("audit", isDirectory: true)
        var options = try ConnectionProbeDaemon.options([
            "--bind", "127.0.0.1", "--port", "1", "--personal-terminal", "--reply-socket", socket.path,
            "--single-terminal-reply-fallback", "--ambient-rightyo", fake.executable.path,
            "--ambient-rightyo-config", fake.config.path, "--ambient-target", RecipientTestRig.target
        ])
        options.port = 0
        let rig = try await RecipientTestRig.make()
        let connected = ConnectedPeerIDs()
        let (listener, endpoint) = try await ConnectionProbeDaemon.compose(
            options, host: rig.host, hostName: "mac-test", audit: AuditLog(directory: auditDirectory),
            timing: .init(eofGrace: 20, termGrace: 20), log: { connected.record($0) }
        )
        let replyEndpoint = try #require(endpoint)
        let port = try await listener.start()
        try await replyEndpoint.start()
        let pair = try await FallbackSocketPair.connect(port: port, selecting: [RecipientTestRig.target])
        defer { pair.close() }
        let wiring = await listener.ambient
        let router = try #require(wiring as? AmbientRightyoRouter)

        let stream = UUID()
        try await recipientSocketSend(audio(stream, 0), on: pair.sockets[0])
        try await recipientSocketSend(audio(stream, 1, final: true), on: pair.sockets[0])
        try await pair.barrier()
        await router.settle()
        #expect(await rig.adapter.contexts.count == 1)

        let peer = try #require(connected.all.first)
        let request = LocalDispatchRequest(connection: peer, target: RecipientTestRig.target,
                                           binding: "reply-binding", text: "synthetic input")
        let answer = try await socketExchange(JSONEncoder().encode(request), path: socket.path)
        #expect(answer.contains("\"delivered\":1"))
        #expect(await rig.adapter.contexts.count == 2)

        let history = try AuditHistory(directory: auditDirectory).today()
        #expect(history.filter { $0.contains("ambient-dispatch") }.count == 1)
        #expect(history.filter { $0.contains("local-dispatch") }.count == 1)
        await replyEndpoint.stop()
        await listener.stop(reason: "synthetic test complete")
    }
}

/// One newline-terminated request over the owner-only Unix socket; returns the response line.
private func socketExchange(_ data: Data, path: String) async throws -> String {
    let connection = NWConnection(to: .unix(path: path), using: .tcp)
    let resumed = Mutex(false)
    defer { connection.cancel() }
    return try await withCheckedThrowingContinuation { continuation in
        @Sendable func finish(_ result: Result<String, any Error>) {
            guard !resumed.withLock({ seen in defer { seen = true }; return seen }) else { return }
            continuation.resume(with: result)
        }
        @Sendable func receive(_ buffer: Data) {
            connection.receive(minimumIncompleteLength: 1, maximumLength: 4_096) { chunk, _, done, error in
                if let error { return finish(.failure(error)) }
                let buffer = buffer + (chunk ?? Data())
                if let newline = buffer.firstIndex(of: 10) {
                    return finish(.success(String(bytes: buffer[..<newline], encoding: .utf8) ?? ""))
                }
                if done { return finish(.failure(TestSupportError.expectedOneControl)) }
                receive(buffer)
            }
        }
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.send(content: data + Data([10]), completion: .contentProcessed { error in
                    if let error { finish(.failure(error)) } else { receive(Data()) }
                })
            case .failed(let error): finish(.failure(error))
            default: break
            }
        }
        connection.start(queue: DispatchQueue(label: "hail.ambient-audit-test"))
    }
}
#endif
