import Foundation
import HailProtocol
import Network
import Testing
@testable import HailDaemonKit

// Socket security, deadline, and full delivery proofs intentionally share their integration helpers.
// swiftlint:disable file_length

// The serialized suite owns one endpoint at a time and deliberately shares its socket test harness.
// swiftlint:disable:next type_body_length
@Suite(.serialized) struct LocalReplyEndpointTests {
    @Test func refusesSocketBelowOtherWritableAncestor() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hs-unsafe-\(UUID().uuidString.prefix(8))", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: scratch) }
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        #expect(chmod(scratch.path, 0o777) == 0)
        let listener = try await testListener()
        let socket = scratch.appendingPathComponent("private", isDirectory: true)
            .appendingPathComponent(LocalReplyEndpoint.socketName)
        #expect(throws: LocalReplyEndpointError.self) {
            _ = try LocalReplyEndpoint(
                socketURL: socket, destination: listener,
                audit: AuditLog(directory: scratch.appendingPathComponent("audit"))
            )
        }
    }

    @Test func resolvesSymlinkBeforeCheckingSocketAncestors() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hs-link-\(UUID().uuidString.prefix(8))", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: scratch) }
        let unsafe = scratch.appendingPathComponent("unsafe", isDirectory: true)
        let victim = unsafe.appendingPathComponent("victim", isDirectory: true)
        let safe = scratch.appendingPathComponent("safe", isDirectory: true)
        try FileManager.default.createDirectory(
            at: victim.appendingPathComponent("config"), withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: safe, withIntermediateDirectories: true)
        #expect(chmod(unsafe.path, 0o777) == 0)
        try FileManager.default.createSymbolicLink(
            at: safe.appendingPathComponent("link"), withDestinationURL: victim
        )
        let listener = try await testListener()
        let socket = safe.appendingPathComponent("link/config/\(LocalReplyEndpoint.socketName)")
        var refused = false
        do {
            _ = try LocalReplyEndpoint(
                socketURL: socket, destination: listener,
                audit: AuditLog(directory: scratch.appendingPathComponent("audit"))
            )
        } catch {
            refused = true
        }
        #expect(refused)
    }

    @Test func refusesWritableACLAncestor() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hs-acl-\(UUID().uuidString.prefix(8))", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: scratch) }
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        let chmod = Process()
        chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
        chmod.arguments = ["+a", "everyone allow add_file", scratch.path]
        try chmod.run()
        chmod.waitUntilExit()
        #expect(chmod.terminationStatus == 0)
        let listener = try await testListener()
        let socket = scratch.appendingPathComponent("private", isDirectory: true)
            .appendingPathComponent(LocalReplyEndpoint.socketName)
        #expect(throws: LocalReplyEndpointError.self) {
            _ = try LocalReplyEndpoint(
                socketURL: socket, destination: listener,
                audit: AuditLog(directory: scratch.appendingPathComponent("audit"))
            )
        }
    }

    @Test func incompleteConnectionExpires() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hs-timeout-\(UUID().uuidString.prefix(8))", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: scratch) }
        let listener = try await testListener()
        let socket = scratch.appendingPathComponent("config", isDirectory: true)
            .appendingPathComponent(LocalReplyEndpoint.socketName)
        let endpoint = try LocalReplyEndpoint(
            socketURL: socket, destination: listener,
            audit: AuditLog(directory: scratch.appendingPathComponent("audit")),
            requestTimeout: .milliseconds(50)
        )
        try await endpoint.start()
        let idle = NWConnection(to: .unix(path: socket.path), using: .tcp)
        idle.start(queue: DispatchQueue(label: "hail.local-reply-idle-test"))
        try await waitUntil { await endpoint.activeConnectionCount == 1 }
        try await Task.sleep(for: .milliseconds(100))
        #expect(await endpoint.activeConnectionCount == 0)
        idle.cancel()
        await endpoint.stop()
    }

    @Test func completedFrameDisarmsRequestDeadline() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hs-complete-\(UUID().uuidString.prefix(8))", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: scratch) }
        let listener = try await testListener()
        let socket = scratch.appendingPathComponent("config", isDirectory: true)
            .appendingPathComponent(LocalReplyEndpoint.socketName)
        let endpoint = try LocalReplyEndpoint(
            socketURL: socket, destination: listener,
            audit: AuditLog(directory: scratch.appendingPathComponent("audit")),
            requestTimeout: .milliseconds(50)
        )
        try await endpoint.start()
        let client = NWConnection(to: .unix(path: socket.path), using: .tcp)
        client.start(queue: DispatchQueue(label: "hail.local-reply-complete-test"))
        try await waitUntil { await endpoint.activeConnectionCount == 1 }
        let id = try #require(await endpoint.awaitingFrameIDs.first)
        await endpoint.frameCompleted(id)
        try await Task.sleep(for: .milliseconds(100))
        #expect(await endpoint.activeConnectionCount == 1)
        client.cancel()
        await endpoint.stop()
    }

    @Test func submissionDeadlineCancelsBlockedPublish() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hpt-\(UUID().uuidString.prefix(8))", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: scratch) }
        let publisher = BlockingReplyPublisher()
        let socket = scratch.appendingPathComponent("config", isDirectory: true)
            .appendingPathComponent(LocalReplyEndpoint.socketName)
        let endpoint = try LocalReplyEndpoint(
            socketURL: socket, destination: publisher,
            audit: AuditLog(directory: scratch.appendingPathComponent("audit")),
            submissionTimeout: .milliseconds(50)
        )
        try await endpoint.start()
        let client = try sendWithoutResponse(replyFrame(), socket: socket.path)
        try await waitUntil { await publisher.started }
        try await waitUntil { await publisher.cancelled }
        #expect(await endpoint.activeConnectionCount == 0)
        client.cancel()
        await endpoint.stop()
    }

    @Test func stopCancelsBlockedPublish() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hps-\(UUID().uuidString.prefix(8))", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: scratch) }
        let publisher = BlockingReplyPublisher()
        let socket = scratch.appendingPathComponent("config", isDirectory: true)
            .appendingPathComponent(LocalReplyEndpoint.socketName)
        let endpoint = try LocalReplyEndpoint(
            socketURL: socket, destination: publisher,
            audit: AuditLog(directory: scratch.appendingPathComponent("audit"))
        )
        try await endpoint.start()
        let client = try sendWithoutResponse(replyFrame(), socket: socket.path)
        try await waitUntil { await publisher.started }
        await endpoint.stop()
        try await waitUntil { await publisher.cancelled }
        #expect(await endpoint.activeConnectionCount == 0)
        client.cancel()
    }

    // The full socket-to-terminal proof deliberately keeps setup, assertion, and teardown in one scope.
    // swiftlint:disable:next function_body_length
    @Test func privateLocalSubmissionReachesOnlyProvenOriginAndIsAudited() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hs-\(UUID().uuidString.prefix(8))", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: scratch) }
        let rig = try await RecipientTestRig.make()
        let listener = try WebSocketListener(
            bindAddress: "127.0.0.1", port: 0, host: rig.host,
            authorizer: PersonalTerminalAuthorizer(), hostName: "mac-test"
        )
        let port = try await listener.start()
        let config = scratch.appendingPathComponent("config", isDirectory: true)
        let socket = config.appendingPathComponent(LocalReplyEndpoint.socketName)
        let auditDirectory = config.appendingPathComponent("audit", isDirectory: true)
        let audit = AuditLog(directory: auditDirectory)
        let endpoint = try LocalReplyEndpoint(socketURL: socket, destination: listener, audit: audit)
        try await endpoint.start()

        let (session, terminal) = try terminalClient(port: port)
        defer {
            terminal.cancel(with: .normalClosure, reason: nil)
            session.invalidateAndCancel()
        }
        do {
            try await terminal.send(.data(FrameCoding.encode(helloFrame())))
            _ = try await terminal.receive()
            try await terminal.send(.data(FrameCoding.encode(
                sessionFrame(payload: .control(.select(targetID: RecipientTestRig.target)))
            )))
            try await recipientSocketBarrier(on: terminal)
            try await recipientSocketSend(sessionFrame(
                target: RecipientTestRig.target, payload: .text(TextPayload(text: "synthetic input"))
            ), on: terminal)
            try await recipientSocketBarrier(on: terminal)
            let context = try #require(await rig.adapter.contexts.last)
            let frame = recipientText(recipientDescriptor(context))
            let response = try await submit(frame, socket: socket.path)
            try #require(response == LocalReplyResponse(delivered: 1))
            #expect(try await terminalFrame(terminal) == frame)
            for requestID in [UUID?.none, UUID()] {
                var unproven = recipientDescriptor(context)
                unproven.requestID = requestID
                let refused = try await submit(recipientText(unproven), socket: socket.path)
                #expect(refused == LocalReplyResponse(
                    delivered: 0, error: LocalReplyRefusal.noRecipient.message, code: .noRecipient
                ))
                try await recipientSocketBarrier(on: terminal)
            }
            var info = stat()
            try #require(lstat(socket.path, &info) == 0)
            #expect(info.st_mode & 0o777 == 0o600)
            let history = try AuditHistory(directory: auditDirectory).today()
            #expect(history.filter { $0.contains("\"kind\":\"pushed\"") }.count == 3)
        } catch {
            await endpoint.stop()
            await listener.stop(reason: "test failed")
            throw error
        }
        await endpoint.stop()
        await listener.stop(reason: "test complete")
        #expect(!FileManager.default.fileExists(atPath: socket.path))
    }

    @Test(arguments: [
        (false, "mac-main", LocalReplyRefusal.listenerNotReady),
        (true, "other-host", LocalReplyRefusal.sourceHostMismatch)
    ])
    func localRefusalNamesTheHostFailure(
        startListener: Bool, source: String, expected: LocalReplyRefusal
    ) async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hs-refusal-\(UUID().uuidString.prefix(8))", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: scratch) }
        let listener = try await testListener()
        if startListener { _ = try await listener.start() }
        let socket = scratch.appendingPathComponent("config", isDirectory: true)
            .appendingPathComponent(LocalReplyEndpoint.socketName)
        let endpoint = try LocalReplyEndpoint(
            socketURL: socket, destination: listener,
            audit: AuditLog(directory: scratch.appendingPathComponent("audit"))
        )
        try await endpoint.start()
        let reply = ReplyDescriptor(id: UUID(), hostID: source, targetID: "tmux:reply")
        let frame = Frame(
            timestamp: 1, target: reply.targetID, source: reply.hostID,
            payload: .text(TextPayload(text: "ready", reply: reply))
        )
        let response = try await submit(frame, socket: socket.path)
        #expect(response == LocalReplyResponse(delivered: 0, error: expected.message, code: expected))
        await endpoint.stop()
        await listener.stop(reason: "test complete")
    }

    @Test func localRefusalNamesInvalidReplyPayload() async throws {
        var frame = replyFrame()
        frame.payload = .text(TextPayload(text: "draft", isFinal: false, reply: replyDescriptor(frame)))
        let listener = try await testListener()
        _ = try await listener.start()
        try await expectRefusal(
            FrameCoding.encode(frame), destination: listener, expected: .invalidReplyPayload
        )
        await listener.stop(reason: "test complete")
    }

    @Test func localRefusalNamesMissingTarget() async throws {
        let frame = Frame(timestamp: 1, source: "mac-main", payload: .text(TextPayload(text: "ready")))
        try await expectRefusal(
            FrameCoding.encode(frame), destination: testListener(), expected: .replyTargetMissing
        )
    }

    @Test func localRefusalNamesDecodeFailure() async throws {
        try await expectRefusal(Data("not-json".utf8), destination: testListener(), expected: .decodeFailure)
    }

    @Test func localRefusalNamesAuditFailure() async throws {
        try await expectRefusal(
            FrameCoding.encode(replyFrame()), destination: testListener(), expected: .auditFailure,
            auditClock: { Date(timeIntervalSince1970: 0) }
        )
    }

    @Test func localRefusalHidesUnexpectedPublisherError() async throws {
        try await expectRefusal(
            FrameCoding.encode(replyFrame()), destination: FailingReplyPublisher(), expected: .internalFailure
        )
    }

    @Test(arguments: [LocalReplyRefusal.requestPending, .noRecipient, .notUniqueRecipient, .publicationFailed])
    func correlatedRefusalPreservesItsTypedWireCode(reason: LocalReplyRefusal) async throws {
        try await expectRefusal(
            FrameCoding.encode(replyFrame()), destination: RefusingReplyPublisher(reason: reason), expected: reason
        )
    }

    @Test(arguments: [0, 2])
    func nonUniqueDeliveryCountCannotBeReportedAsSuccess(count: Int) async throws {
        try await expectRefusal(
            FrameCoding.encode(replyFrame()), destination: CountingReplyPublisher(count: count),
            expected: count == 0 ? .noRecipient : .publicationFailed
        )
    }

    // The full socket-to-pane-to-terminal dispatch proof keeps setup, assertions and teardown in one scope.
    // swiftlint:disable:next function_body_length
    @Test func dispatchOverTheSocketMintsAnOwnedRequestWhileRepliesAreUnchanged() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hs-dispatch-\(UUID().uuidString.prefix(8))", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: scratch) }
        let rig = try await RecipientTestRig.make()
        let (listener, connected) = try dispatchListener(rig: rig)
        let port = try await listener.start()
        let config = scratch.appendingPathComponent("config", isDirectory: true)
        let socket = config.appendingPathComponent(LocalReplyEndpoint.socketName)
        let auditDirectory = config.appendingPathComponent("audit", isDirectory: true)
        let endpoint = try LocalReplyEndpoint(
            socketURL: socket, destination: listener, audit: AuditLog(directory: auditDirectory)
        )
        try await endpoint.start()
        let (session, terminal) = try terminalClient(port: port)
        defer {
            terminal.cancel(with: .normalClosure, reason: nil)
            session.invalidateAndCancel()
        }
        do {
            try await terminal.send(.data(FrameCoding.encode(helloFrame())))
            _ = try await terminal.receive()
            try await terminal.send(.data(FrameCoding.encode(
                sessionFrame(payload: .control(.select(targetID: RecipientTestRig.target)))
            )))
            try await recipientSocketBarrier(on: terminal)
            let connection = try #require(connected.all.first)
            // The exact wire shape `haild rightyo --reply-to` will write, by hand.
            let raw = Data("""
            {"kind":"dispatch","connection":"\(connection.uuidString)","target":"\(RecipientTestRig.target)",\
            "binding":"reply-binding","text":"synthetic input"}
            """.utf8)
            let dispatched = try await submit(raw, socket: socket.path)
            let owner = try #require(dispatched.request)
            #expect(dispatched == .dispatch(delivered: 1, request: owner))
            let context = try #require(await rig.adapter.contexts.last)
            #expect(context.id == owner)
            try await recipientSocketBarrier(on: terminal)
            // The pane answers through the unchanged correlated path; the reply response carries no `request`.
            let frame = recipientText(recipientDescriptor(context))
            let replied = try await submit(frame, socket: socket.path)
            #expect(replied == LocalReplyResponse(delivered: 1))
            #expect(!replied.isDispatch)
            #expect(try await terminalFrame(terminal) == frame)
            // An explicit legacy `kind` is still a reply frame; a stale connection id refuses in dispatch shape.
            var tagged = try #require(JSONSerialization.jsonObject(with: FrameCoding.encode(frame)) as? [String: Any])
            tagged["kind"] = "reply"
            let duplicate = try await submit(JSONSerialization.data(withJSONObject: tagged), socket: socket.path)
            #expect(duplicate == LocalReplyResponse(
                delivered: 0, error: LocalReplyRefusal.noRecipient.message, code: .noRecipient
            ))
            let stale = LocalDispatchRequest(
                connection: UUID(), target: RecipientTestRig.target, binding: "reply-binding", text: "x"
            )
            let refused = try await submit(JSONEncoder().encode(stale), socket: socket.path)
            #expect(refused == .dispatch(
                delivered: 0, request: nil, error: LocalDispatchRefusal.unknownConnection.message,
                code: .noRecipient
            ))
            try await recipientSocketBarrier(on: terminal)
            #expect(await rig.adapter.contexts.count == 1)
            let history = try AuditHistory(directory: auditDirectory).today()
            #expect(history.filter { $0.contains("\"kind\":\"pushed\"") }.count == 4)
            #expect(history.filter { $0.contains("local-dispatch") }.count == 2)
        } catch {
            await endpoint.stop()
            await listener.stop(reason: "test failed")
            throw error
        }
        await endpoint.stop()
        await listener.stop(reason: "test complete")
    }

    @Test func dispatchToALegacyAdapterReportsAnExplicitNullRequest() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hs-ld-\(UUID().uuidString.prefix(8))", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: scratch) }
        let (listener, adapter) = try await legacyReplyListener()
        let port = try await listener.start()
        let socket = scratch.appendingPathComponent("config", isDirectory: true)
            .appendingPathComponent(LocalReplyEndpoint.socketName)
        let endpoint = try LocalReplyEndpoint(
            socketURL: socket, destination: listener,
            audit: AuditLog(directory: scratch.appendingPathComponent("audit"))
        )
        try await endpoint.start()
        let (session, terminal) = try terminalClient(port: port)
        defer {
            terminal.cancel(with: .normalClosure, reason: nil)
            session.invalidateAndCancel()
        }
        do {
            try await terminal.send(.data(FrameCoding.encode(helloFrame())))
            _ = try await terminal.receive()
            let select = sessionFrame(payload: .control(.select(targetID: "tmux:reply")))
            try await recipientSocketSend(select, on: terminal)
            try await recipientSocketBarrier(on: terminal)
            let peers = await listener.peers
            let connection = try #require(peers.keys.first)
            let request = LocalDispatchRequest(
                connection: connection, target: "tmux:reply", binding: "binding", text: "ready"
            )
            let response = try await submit(JSONEncoder().encode(request), socket: socket.path)
            #expect(response == .dispatch(delivered: 1, request: nil))
            #expect(response.isDispatch)
            #expect(await adapter.deliveries == [.init(target: "reply", text: "ready", binding: "binding")])
        } catch {
            await endpoint.stop()
            await listener.stop(reason: "test failed")
            throw error
        }
        await endpoint.stop()
        await listener.stop(reason: "test complete")
    }

    /// #200: a RightyO-sized dispatch (1 MiB, every character JSON-escaped, so a ~2 MiB line) crosses the
    /// socket and is delivered; a reply frame over its own unchanged cap is still refused as before.
    @Test func mebibyteDispatchCrossesTheSocketWhileReplyFramesKeepTheirCap() async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("hs-cap-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        // An anchored guard keeps a 1 MiB prompt inside the per-rule budget; guard parity has its own suite.
        let (listener, adapter) = try await legacyReplyListener(guards: [.init(name: "synthetic", regex: "^x$")])
        let port = try await listener.start()
        let socket = scratch.appendingPathComponent("config", isDirectory: true)
            .appendingPathComponent(LocalReplyEndpoint.socketName)
        let audit = AuditLog(directory: scratch.appendingPathComponent("audit"))
        let endpoint = try LocalReplyEndpoint(socketURL: socket, destination: listener, audit: audit)
        try await endpoint.start()
        let (session, terminal) = try terminalClient(port: port)
        defer { terminal.cancel(with: .normalClosure, reason: nil); session.invalidateAndCancel() }
        do {
            try await terminal.send(.data(FrameCoding.encode(helloFrame())))
            _ = try await terminal.receive()
            let select = sessionFrame(payload: .control(.select(targetID: "tmux:reply")))
            try await recipientSocketSend(select, on: terminal)
            try await recipientSocketBarrier(on: terminal)
            let connection = try #require(await listener.peers.keys.first)
            let text = String(repeating: #""/"#, count: 1 << 19)
            let line = try JSONEncoder().encode(LocalDispatchRequest(
                connection: connection, target: "tmux:reply", binding: "binding", text: text
            ))
            #expect(line.count > 2 * (1 << 20) && line.count <= LocalDispatchRequest.maxLineBytes)
            #expect(try await submit(line, socket: socket.path) == .dispatch(delivered: 1, request: nil))
            #expect(await adapter.deliveries.map(\.text) == [text])
            let reply = Data("{\"x\":\"\(String(repeating: "a", count: PayloadLimits.defaultMaxFrameBytes))\"}".utf8)
            #expect(try await submit(reply, socket: socket.path) == .init(delivered: 0, error: "frame too large"))
        } catch {
            await endpoint.stop()
            await listener.stop(reason: "test failed")
            throw error
        }
        await endpoint.stop()
        await listener.stop(reason: "test complete")
    }

    /// #204: a dispatch whose typing outlives the endpoint's submission deadline is abandoned before its commit
    /// point (no further chunk, no Enter; the typed prefix stays unsubmitted, there is no rollback), and a retry
    /// through a patient endpoint presses Enter exactly once.
    @Test func timedOutDispatchNeverPressesEnterAndARetrySubmitsOnce() async throws {
        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("hs-dl-\(UUID().uuidString.prefix(8))", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let runner = FakeCommandRunner.serving(SessionListing(bridgeListing), delay: .milliseconds(20))
        let listener = try await slowTmuxListener(runner)
        let port = try await listener.start()
        let config = scratch.appendingPathComponent("config", isDirectory: true)
        let audit = AuditLog(directory: scratch.appendingPathComponent("audit"))
        let hasty = try LocalReplyEndpoint(
            socketURL: config.appendingPathComponent("hasty.sock"), destination: listener, audit: audit,
            submissionTimeout: .milliseconds(300)
        )
        let patient = try LocalReplyEndpoint(
            socketURL: config.appendingPathComponent("patient.sock"), destination: listener, audit: audit
        )
        try await hasty.start()
        try await patient.start()
        let (session, terminal) = try terminalClient(port: port)
        defer { terminal.cancel(with: .normalClosure, reason: nil); session.invalidateAndCancel() }
        do {
            let connection = try await selectOrdinary(on: terminal, listener: listener)
            // 40 chunks at 20 ms each: far past the 300 ms deadline.
            let text = String(repeating: "a", count: 40 * TmuxAdapter.defaultChunkSize)
            let line = try JSONEncoder().encode(LocalDispatchRequest(
                connection: connection, target: "tmux:ordinary", binding: "$2@1758230001/%2:502", text: text
            ))
            await #expect(throws: (any Error).self) { try await submit(line, socket: hasty.socketURL.path) }
            #expect(try await submit(line, socket: patient.socketURL.path) == .dispatch(delivered: 1, request: nil))
            let keys = await runner.calls.compactMap { $0.contains("send-keys") ? $0.last : nil }
            #expect(!keys.contains("C-u"))
            #expect(keys.filter { $0 == "Enter" } == ["Enter"])
            #expect(keys.last == "Enter")
            // The abandoned attempt typed fewer than its 40 chunks; the retry typed all 40 after them.
            let typed = keys.dropLast()
            #expect(typed.count > 40 && typed.count < 80)
            #expect(typed.suffix(40).joined() == text)
        } catch {
            await stopAll(hasty, patient, listener)
            throw error
        }
        await stopAll(hasty, patient, listener)
    }

    @Test func ownershipLostAfterHandoffReportsDeliveredWithoutARequest() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hs-ol-\(UUID().uuidString.prefix(8))", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: scratch) }
        let socket = scratch.appendingPathComponent("config", isDirectory: true)
            .appendingPathComponent(LocalReplyEndpoint.socketName)
        let endpoint = try LocalReplyEndpoint(
            socketURL: socket, destination: RefusingDispatchPublisher(reason: .ownershipLost),
            audit: AuditLog(directory: scratch.appendingPathComponent("audit"))
        )
        try await endpoint.start()
        let request = LocalDispatchRequest(connection: UUID(), target: "tmux:reply", binding: "binding", text: "x")
        // The handoff completed, so `delivered` is honest; `request` is explicit null and the reason is named.
        #expect(try await submit(JSONEncoder().encode(request), socket: socket.path) == .dispatch(
            delivered: 1, request: nil, error: LocalDispatchRefusal.ownershipLost.message, code: .publicationFailed
        ))
        await endpoint.stop()
    }

    @Test func dispatchSharesTheReplyAdmissionBudget() async throws {
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
            "hs-db-\(UUID().uuidString.prefix(8))", isDirectory: true
        )
        defer { try? FileManager.default.removeItem(at: scratch) }
        let socket = scratch.appendingPathComponent("config", isDirectory: true)
            .appendingPathComponent(LocalReplyEndpoint.socketName)
        let endpoint = try LocalReplyEndpoint(
            socketURL: socket, destination: await testListener(),
            audit: AuditLog(directory: scratch.appendingPathComponent("audit"))
        )
        try await endpoint.start()
        await endpoint.exhaustAdmissionBudget()
        let request = LocalDispatchRequest(connection: UUID(), target: "tmux:reply", binding: "binding", text: "x")
        let limited = LocalReplyResponse(delivered: 0, error: "rate limited")
        #expect(try await submit(JSONEncoder().encode(request), socket: socket.path) == limited)
        #expect(try await submit(replyFrame(), socket: socket.path) == limited)
        await endpoint.stop()
    }

    @Test func localRefusalCodesRemainBoundedAndStable() throws {
        for reason in [LocalReplyRefusal.sourceHostMismatch, .listenerNotReady, .invalidReplyPayload,
                       .replyTargetMissing, .auditFailure, .decodeFailure, .internalFailure,
                       .noRecipient, .requestPending, .notUniqueRecipient, .publicationFailed] {
            #expect(reason.message.count <= ControlLimits.maxErrorMessage)
            #expect(try JSONDecoder().decode(LocalReplyRefusal.self, from: JSONEncoder().encode(reason)) == reason)
        }
    }
}

private struct RefusingReplyPublisher: HostReplyPublishing {
    let reason: LocalReplyRefusal
    func publish(_ frame: Frame) async throws -> Int { throw reason }
}

private struct RefusingDispatchPublisher: HostReplyPublishing {
    let reason: LocalDispatchRefusal
    func publish(_ frame: Frame) async throws -> Int { throw LocalReplyRefusal.noRecipient }
    func dispatch(_ request: LocalDispatchRequest) async throws -> UUID? { throw reason }
}

private struct CountingReplyPublisher: HostReplyPublishing {
    let count: Int
    func publish(_ frame: Frame) async throws -> Int { count }
}

private func replyDescriptor(_ frame: Frame) -> ReplyDescriptor? {
    guard case .text(let text) = frame.payload else { return nil }
    return text.reply
}

private func expectRefusal(
    _ data: Data, destination: any HostReplyPublishing, expected: LocalReplyRefusal,
    auditClock: @escaping @Sendable () -> Date = { Date() }
) async throws {
    let scratch = FileManager.default.temporaryDirectory.appendingPathComponent(
        "hs-refusal-\(UUID().uuidString.prefix(8))", isDirectory: true
    )
    defer { try? FileManager.default.removeItem(at: scratch) }
    let socket = scratch.appendingPathComponent("config", isDirectory: true)
        .appendingPathComponent(LocalReplyEndpoint.socketName)
    let endpoint = try LocalReplyEndpoint(
        socketURL: socket, destination: destination,
        audit: AuditLog(directory: scratch.appendingPathComponent("audit"), now: auditClock)
    )
    try await endpoint.start()
    let response = try await submit(data, socket: socket.path)
    #expect(response == LocalReplyResponse(delivered: 0, error: expected.message, code: expected))
    await endpoint.stop()
}

private func selectOrdinary(on terminal: URLSessionWebSocketTask, listener: WebSocketListener) async throws -> UUID {
    try await terminal.send(.data(FrameCoding.encode(helloFrame())))
    _ = try await terminal.receive()
    try await recipientSocketSend(sessionFrame(payload: .control(.select(targetID: "tmux:ordinary"))), on: terminal)
    try await recipientSocketBarrier(on: terminal)
    return try #require(await listener.peers.keys.first)
}

private func stopAll(_ first: LocalReplyEndpoint, _ second: LocalReplyEndpoint, _ listener: WebSocketListener) async {
    await first.stop()
    await second.stop()
    await listener.stop(reason: "test complete")
}

/// The production `TmuxAdapter` behind a scripted, slow runner; `tmux:ordinary` allowed at the open tier.
private func slowTmuxListener(_ runner: FakeCommandRunner) async throws -> WebSocketListener {
    let registry = Registry()
    try await registry.register(TmuxAdapter(runner: runner, pollInterval: nil))
    var policy = Policy(guardPatterns: [.init(name: "synthetic", regex: "^x$")])
    try policy.allow("tmux:ordinary", binding: "$2@1758230001/%2:502", tier: .open)
    let host = try HailHost(registry: registry, store: InMemoryPolicyStore(policy))
    return try WebSocketListener(
        bindAddress: "127.0.0.1", port: 0, host: host, authorizer: PersonalTerminalAuthorizer(), hostName: "mac-main"
    )
}

/// One allowed legacy `tmux:` target: generic input only, so no reply ownership can be minted for it.
private func legacyReplyListener(
    guards: [GuardPattern] = DangerousPatternGuard.defaults
) async throws -> (WebSocketListener, FakeAdapter) {
    var policy = Policy(guardPatterns: guards)
    try policy.allow("tmux:reply", binding: "binding", tier: .open)
    let (host, adapter) = try await sessionHost(
        targets: [AdapterTarget(name: "reply", binding: "binding")], policy: policy
    )
    let listener = try WebSocketListener(
        bindAddress: "127.0.0.1", port: 0, host: host, authorizer: PersonalTerminalAuthorizer(), hostName: "mac-main"
    )
    return (listener, adapter)
}

private func testListener() async throws -> WebSocketListener {
    let (host, _) = try await sessionHost()
    return try WebSocketListener(
        bindAddress: "127.0.0.1", port: 0, host: host,
        authorizer: PersonalTerminalAuthorizer(), hostName: "mac-main"
    )
}

private func replyFrame() -> Frame {
    let reply = ReplyDescriptor(id: UUID(), hostID: "mac-main", targetID: "tmux:reply")
    return Frame(
        timestamp: 1, target: reply.targetID, source: reply.hostID,
        payload: .text(TextPayload(text: "ready", reply: reply))
    )
}

private func sendWithoutResponse(_ frame: Frame, socket: String) throws -> NWConnection {
    var encoded = try FrameCoding.encode(frame)
    encoded.append(UInt8(ascii: "\n"))
    let request = encoded
    let connection = NWConnection(to: .unix(path: socket), using: .tcp)
    connection.stateUpdateHandler = { state in
        guard case .ready = state else { return }
        connection.send(content: request, contentContext: .defaultMessage, isComplete: false, completion: .idempotent)
    }
    connection.start(queue: DispatchQueue(label: "hail.local-reply-send-only-test"))
    return connection
}

private func waitUntil(_ predicate: @escaping @Sendable () async -> Bool) async throws {
    for _ in 0..<100 {
        if await predicate() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw LocalReplyEndpointError.failed("condition timed out")
}

private func terminalClient(port: UInt16) throws -> (URLSession, URLSessionWebSocketTask) {
    let session = URLSession(configuration: .ephemeral)
    let url = try #require(URL(string: "ws://127.0.0.1:\(port)"))
    let socket = session.webSocketTask(with: url, protocols: [WebSocketListener.subprotocolName])
    socket.resume()
    return (session, socket)
}

private func terminalFrame(_ socket: URLSessionWebSocketTask) async throws -> Frame {
    switch try await socket.receive() {
    case .data(let data): try FrameCoding.decode(data)
    case .string(let text): try FrameCoding.decode(Data(text.utf8))
    @unknown default: throw TestSupportError.expectedOneControl
    }
}

private func submit(_ frame: Frame, socket: String) async throws -> LocalReplyResponse {
    try await submit(FrameCoding.encode(frame), socket: socket)
}

private func submit(_ data: Data, socket: String) async throws -> LocalReplyResponse {
    let connection = NWConnection(to: .unix(path: socket), using: .tcp)
    let queue = DispatchQueue(label: "hail.local-reply-test")
    var encoded = data
    encoded.append(UInt8(ascii: "\n"))
    let request = encoded
    return try await withCheckedThrowingContinuation { continuation in
        let completion = LocalReplyTestCompletion(continuation)
        connection.stateUpdateHandler = { state in
            switch state {
            case .ready:
                connection.send(
                    content: request, contentContext: .defaultMessage, isComplete: false,
                    completion: .contentProcessed { error in
                        if let error { completion.fail(error) } else {
                            receiveResponse(connection, completion: completion, buffer: Data())
                        }
                    }
                )
            case .failed(let error): completion.fail(error)
            default: break
            }
        }
        connection.start(queue: queue)
    }
}

private actor FailingReplyPublisher: HostReplyPublishing {
    func publish(_ frame: Frame) async throws -> Int {
        _ = frame
        throw LocalReplyEndpointError.failed("private diagnostic must not reach the client")
    }
}

private func receiveResponse(
    _ connection: NWConnection, completion: LocalReplyTestCompletion, buffer: Data
) {
    connection.receive(minimumIncompleteLength: 1, maximumLength: 1_024) { data, _, done, error in
        if let error { completion.fail(error); return }
        var response = buffer
        if let data { response.append(data) }
        if let newline = response.firstIndex(of: UInt8(ascii: "\n")) {
            do {
                completion.succeed(try JSONDecoder().decode(LocalReplyResponse.self, from: response[..<newline]))
            } catch {
                completion.fail(error)
            }
            connection.cancel()
        } else if done {
            completion.fail(LocalReplyEndpointError.failed("response ended early"))
        } else {
            receiveResponse(connection, completion: completion, buffer: response)
        }
    }
}

private final class LocalReplyTestCompletion: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<LocalReplyResponse, any Error>?

    init(_ continuation: CheckedContinuation<LocalReplyResponse, any Error>) {
        self.continuation = continuation
    }

    func succeed(_ response: LocalReplyResponse) { finish(.success(response)) }
    func fail(_ error: any Error) { finish(.failure(error)) }

    private func finish(_ result: Result<LocalReplyResponse, any Error>) {
        let pending = lock.withLock {
            let pending = continuation
            continuation = nil
            return pending
        }
        pending?.resume(with: result)
    }
}

private actor BlockingReplyPublisher: HostReplyPublishing {
    private(set) var started = false
    private(set) var cancelled = false
    private var continuation: CheckedContinuation<Int, any Error>?

    func publish(_ frame: Frame) async throws -> Int {
        _ = frame
        started = true
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation = $0 }
        } onCancel: {
            Task { await self.cancel() }
        }
    }

    private func cancel() {
        cancelled = true
        continuation?.resume(throwing: CancellationError())
        continuation = nil
    }
}
