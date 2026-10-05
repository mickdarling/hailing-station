#if os(macOS)
public import Foundation

public enum DiagnosticReplyCompositionError: Error, Sendable, Equatable {
    case alreadyStarted, stopped
}

/// Explicit library composition only: no daemon flag, policy grant or target selection is installed.
/// The trusted owner must retain this lifetime and call stop on shutdown/startup failure.
public actor DiagnosticReplyComposition {
    public struct Configuration: Sendable {
        public let executable: URL
        public let socket: URL
        public let outputRoot: URL
        public let hostID: String

        public init(executable: URL, socket: URL, outputRoot: URL, hostID: String) {
            self.executable = executable
            self.socket = socket
            self.outputRoot = outputRoot
            self.hostID = hostID
        }
    }

    private enum State { case idle, starting, running, stopped }
    private var state = State.idle
    private let registry: Registry
    private let adapter: DiagnosticReplyBridgeAdapter
    private let publisher: OwnedReplyPublisher
    private let endpoint: LocalReplyEndpoint

    public init(configuration: Configuration, registry: Registry,
                destination: any HostReplyPublishing, audit: AuditLog) throws {
        let publisher = try OwnedReplyPublisher(executable: configuration.executable, socket: configuration.socket,
                                                outputRoot: configuration.outputRoot, hostID: configuration.hostID)
        self.registry = registry
        self.publisher = publisher
        adapter = try DiagnosticReplyBridgeAdapter(hostID: configuration.hostID, publisher: publisher.publish)
        endpoint = try LocalReplyEndpoint(socketURL: configuration.socket, destination: destination, audit: audit)
    }

    // Internal controlled renderer environment/deadline seam, never a mobile or daemon option.
    init(configuration: OwnedReplyPublisherConfiguration, registry: Registry,
         destination: any HostReplyPublishing, audit: AuditLog) throws {
        let publisher = try OwnedReplyPublisher(configuration: configuration)
        self.registry = registry
        self.publisher = publisher
        adapter = try DiagnosticReplyBridgeAdapter(hostID: configuration.hostID, publisher: publisher.publish)
        endpoint = try LocalReplyEndpoint(socketURL: configuration.socket, destination: destination, audit: audit)
    }

    /// Readiness precedes registry visibility; registration does not grant policy or select a client target.
    /// Concurrent stop permanently retires the adapter even if registration was already in flight.
    public func start() async throws {
        guard state == .idle else {
            throw state == .stopped ? DiagnosticReplyCompositionError.stopped : .alreadyStarted
        }
        state = .starting
        do {
            try await withTaskCancellationHandler {
                try Task.checkCancellation()
                try await endpoint.start()
                try Task.checkCancellation()
                guard state == .starting else { throw DiagnosticReplyCompositionError.stopped }
                try await registry.register(adapter)
                try Task.checkCancellation()
                guard state == .starting else { throw DiagnosticReplyCompositionError.stopped }
                state = .running
            } onCancel: {
                Task { await self.stop() }
            }
        } catch {
            await stop()
            throw error
        }
    }

    /// Invalidate publication/admission first, cancel owned groups, then retire the endpoint.
    /// Retained uncertain ownership stays with the publisher; this does not promise kernel cleanup time.
    public func stop() async {
        state = .stopped
        await adapter.stop()
        publisher.stop()
        await endpoint.stop()
    }

    public func bridgeDiagnostics() async -> DiagnosticBridgeDiagnostics { await adapter.diagnostics() }
    public func publisherDiagnostics() -> OwnedReplyPublisherDiagnostics { publisher.diagnostics() }
}
#endif
