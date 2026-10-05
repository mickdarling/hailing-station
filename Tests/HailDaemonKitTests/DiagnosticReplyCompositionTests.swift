#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

@Suite(.serialized) struct DiagnosticReplyCompositionTests {
    @Test func constructionAndStopBeforeStartNeverRegisterOrAdmit() async throws {
        let fixture = try PublisherFixture(cli: true)
        let registry = Registry()
        let composition = try makeComposition(fixture, registry: registry, destination: PublisherEndpointRecorder())
        #expect(await registry.kinds.isEmpty)
        await composition.stop()
        await #expect(throws: DiagnosticReplyCompositionError.stopped) { try await composition.start() }
        #expect(await registry.kinds.isEmpty)
        #expect(await composition.publisherDiagnostics().retained == 0)
        try await removeFixture(fixture, composition: composition)
    }

    @Test func duplicateRegistrationFailureRetiresEndpointAndPublisher() async throws {
        let fixture = try PublisherFixture(cli: true)
        let registry = Registry()
        try await registry.register(DiagnosticReplyBridgeAdapter(hostID: "synthetic-host", publisher: { _ in }))
        let composition = try makeComposition(fixture, registry: registry, destination: PublisherEndpointRecorder())
        await #expect(throws: RegistryError.duplicateKind("diagnostic-reply")) { try await composition.start() }
        #expect(!FileManager.default.fileExists(atPath: fixture.base.appendingPathComponent("reply.sock").path))
        #expect(await composition.bridgeDiagnostics().lastFailure == .stopped)
        await #expect(throws: DiagnosticReplyCompositionError.stopped) { try await composition.start() }
        try await removeFixture(fixture, composition: composition)
    }

    @Test func cancelledStartupPermanentlyRetiresWithoutRegistration() async throws {
        let fixture = try PublisherFixture(cli: true)
        let registry = Registry()
        let composition = try makeComposition(fixture, registry: registry, destination: PublisherEndpointRecorder())
        let start = Task {
            do { try await Task.sleep(for: .seconds(60)) } catch { }
            try await composition.start()
        }
        start.cancel()
        await #expect(throws: CancellationError.self) { try await start.value }
        #expect(await registry.kinds.isEmpty)
        #expect(await composition.bridgeDiagnostics().lastFailure == .stopped)
        try await removeFixture(fixture, composition: composition)
    }

    @Test(arguments: [false, true])
    func realCLIAndTwoSocketsKeepDelayedTextAudioAndFinalOnOrigin(reverseOrder: Bool) async throws {
        let fixture = try PublisherFixture(cli: true)
        let registry = Registry()
        var policy = Policy(guardPatterns: [.init(name: "synthetic guard", regex: "^synthetic guarded command$")],
                            deliveriesPerMinute: 1_000)
        try policy.allow(DiagnosticReplyBridgeAdapter.targetID, binding: diagnosticUtilityBinding, tier: .open)
        let host = try HailHost(registry: registry, store: InMemoryPolicyStore(policy))
        let listener = try WebSocketListener(bindAddress: "127.0.0.1", port: 0, host: host,
                                            authorizer: PersonalTerminalAuthorizer(), hostName: "synthetic-host")
        let destination = CompositionDestination(listener)
        let composition = try makeComposition(fixture, registry: registry, destination: destination)
        do {
            try await composition.start()
            await #expect(throws: DiagnosticReplyCompositionError.alreadyStarted) { try await composition.start() }
            let listing = try await registry.listing()
            #expect(listing.count == 1 && listing[0].binding == diagnosticUtilityBinding)
            let port = try await listener.start()
            try await exerciseSockets(port, reverseOrder: reverseOrder, destination: destination)
            try await PublisherFixture.until { await composition.bridgeDiagnostics().completed == 2 }
            #expect(await composition.publisherDiagnostics().completed == 2)
            await composition.stop()
            #expect(try await registry.targets().allSatisfy { !$0.alive })
            await listener.stop()
            try await removeFixture(fixture, composition: composition)
        } catch {
            await destination.release()
            await composition.stop(); await listener.stop()
            try await removeFixture(fixture, composition: composition)
            throw error
        }
    }

    private func exerciseSockets(_ port: UInt16, reverseOrder: Bool, destination: CompositionDestination) async throws {
        let (firstSession, first) = try recipientSocket(port: port)
        let (secondSession, second) = try recipientSocket(port: port)
        defer {
            first.cancel(with: .normalClosure, reason: nil); second.cancel(with: .normalClosure, reason: nil)
            firstSession.invalidateAndCancel(); secondSession.invalidateAndCancel()
        }
        let sockets = reverseOrder ? [second, first] : [first, second]
        for socket in sockets {
            try await recipientSocketSend(helloFrame(), on: socket)
            _ = try await recipientSocketReceive(on: socket)
            try await recipientSocketSend(sessionFrame(payload: .control(.select(
                targetID: DiagnosticReplyBridgeAdapter.targetID))), on: socket)
            try await recipientSocketBarrier(on: socket)
        }
        let input = sessionFrame(target: DiagnosticReplyBridgeAdapter.targetID,
                                 payload: .text(TextPayload(text: "identical synthetic input")))
        try await recipientSocketSend(input, on: sockets[0])
        try await PublisherFixture.until { await destination.held }
        try await recipientSocketSend(input, on: sockets[1])
        try await PublisherFixture.until { await destination.frames == 4 }
        let secondReply = try await readReply(sockets[1], sequence: 2)
        await destination.release()
        let firstReply = try await readReply(sockets[0], sequence: 1)
        #expect(firstReply.requestID != nil && firstReply.requestID != secondReply.requestID)
        #expect(firstReply.id != secondReply.id && firstReply.audioStreamID != secondReply.audioStreamID)
        for socket in sockets { try await recipientSocketBarrier(on: socket) }
    }

    private func readReply(_ socket: URLSessionWebSocketTask, sequence: Int) async throws -> ReplyDescriptor {
        let textFrame = try await recipientSocketReceive(on: socket)
        guard case .text(let text) = textFrame.payload else { throw TestSupportError.expectedOneControl }
        let descriptor = try #require(text.reply)
        #expect(text.text == "Hailing Station diagnostic reply \(sequence). Over to you.")
        for index in 0...1 {
            let frame = try await recipientSocketReceive(on: socket)
            guard case .audio(let audio) = frame.payload else { throw TestSupportError.expectedOneControl }
            #expect(audio.reply == descriptor && audio.streamID == descriptor.audioStreamID)
            #expect(audio.sequence == index && audio.isFinal == (index == 1))
        }
        return descriptor
    }
}

private func makeComposition(_ fixture: PublisherFixture, registry: Registry, destination: any HostReplyPublishing)
throws -> DiagnosticReplyComposition {
    try DiagnosticReplyComposition(configuration: .init(
        executable: fixture.executable, socket: fixture.base.appendingPathComponent("reply.sock"),
        root: fixture.root, hostID: "synthetic-host", environment: fixture.environment, deadline: .seconds(10)),
        registry: registry, destination: destination,
        audit: AuditLog(directory: fixture.base.appendingPathComponent("audit")))
}

private func removeFixture(_ fixture: PublisherFixture, composition: DiagnosticReplyComposition) async throws {
    await composition.stop()
    try await PublisherFixture.until {
        let status = await composition.publisherDiagnostics()
        return status.retained == 0 && status.queued == 0
    }
    try FileManager.default.removeItem(at: fixture.base)
}

private actor CompositionDestination: HostReplyPublishing {
    let listener: WebSocketListener
    private(set) var held = false
    private(set) var frames = 0
    private var continuation: CheckedContinuation<Void, Never>?
    init(_ listener: WebSocketListener) { self.listener = listener }
    func publish(_ frame: Frame) async throws -> Int {
        let count = try await listener.publish(frame)
        frames += 1
        if !held {
            held = true
            await withCheckedContinuation { continuation = $0 }
        }
        return count
    }
    func release() { continuation?.resume(); continuation = nil }
}
#endif
