#if os(macOS)
public import Foundation
import HailProtocol

/// The final delivery step for ambient RightyO requests (#203): the daemon's own local dispatch for one named
/// connection, so the phone's authorizer, selection generation, rate limits and sanitizer all apply. Returns
/// the reply request the connection now owns, or nil when the adapter cannot own a reply. PR 3 supplies
/// `WebSocketListener.dispatch(_:)`; tests supply a fake. Implementations must not retry.
public protocol RightyoAmbientDispatching: Sendable {
    func dispatch(_ request: LocalDispatchRequest) async throws -> UUID?
}

/// Adapts the consumer's delivery step to a named-connection dispatch. A refusal that follows a completed
/// handoff (`ownershipLost`, `connectionLost`) still landed the prompt, so it is a receipt with a caveat.
struct RightyoAmbientDispatchStep: RightyoDispatching {
    let connection: UUID
    let dispatcher: any RightyoAmbientDispatching

    func dispatch(text: String, target: String, binding: String) async throws -> RightyoDispatchReceipt {
        guard text.utf8.count <= PayloadLimits.maxTextBytes else { throw RightyoInputError.capacity }
        let request = LocalDispatchRequest(connection: connection, target: target, binding: binding, text: text)
        do {
            return RightyoDispatchReceipt(request: try await dispatcher.dispatch(request))
        } catch let refusal as LocalDispatchRefusal where refusal.handedOff {
            return RightyoDispatchReceipt(request: nil, caveat: refusal.message)
        }
    }
}

/// One ambient listening stream (#203): a `rightyo listen --mode stdin` child fed phone audio, whose JSONL
/// passes through `RightyoInputEvent.decode` and a `RightyoInputConsumer` bound to this pipeline's own
/// `hail-<uuid>` session, target and pinned binding. Admitted requests go to the injected dispatcher on behalf
/// of `connection`. Any decode, consumer, dispatch or child failure ends the stream; nothing restarts it.
/// Audio and transcript content are never logged; the summary carries counts only.
public final class RightyoAmbientPipeline: Sendable {
    public struct Configuration: Sendable {
        public var executable: URL
        public var config: URL
        public var target: String
        public var binding: String
        public var connection: UUID
        /// Admit requests whose turns are not `live-microphone`. Tests only; the daemon leaves it false.
        public var allowSynthetic: Bool
        public var timing: RightyoChildProcess.Timing

        public init(executable: URL, config: URL, target: String, binding: String, connection: UUID,
                    allowSynthetic: Bool = false, timing: RightyoChildProcess.Timing = .init()) {
            (self.executable, self.config, self.target, self.binding) = (executable, config, target, binding)
            (self.connection, self.allowSynthetic, self.timing) = (connection, allowSynthetic, timing)
        }
    }

    /// Counts only: never audio or transcript content.
    public struct Summary: Sendable, Equatable {
        public var delivered: Int
        public var child: RightyoChildProcess.Counters
        public var exit: RightyoChildExit
    }

    /// The producer session id handed to the child and required on every event: `hail-<lowercase uuid>`.
    public let session: String
    private let child: RightyoChildProcess
    private let consumer: RightyoInputConsumer

    /// Validates the target and the executable before launching the child; a refusal launches nothing.
    public init(configuration: Configuration, dispatcher: any RightyoAmbientDispatching) throws {
        let session = "hail-\(UUID().uuidString.lowercased())"
        let step = RightyoAmbientDispatchStep(connection: configuration.connection, dispatcher: dispatcher)
        consumer = try RightyoInputConsumer(host: nil, target: configuration.target, binding: configuration.binding,
                                            session: session, allowSynthetic: configuration.allowSynthetic,
                                            dispatcher: step)
        child = try RightyoChildProcess(executable: configuration.executable, config: configuration.config,
                                        session: session, timing: configuration.timing)
        self.session = session
    }

    /// Hands one raw mono 16 kHz s16le chunk to the child without blocking; false once input has closed or for
    /// a chunk that is empty, odd-length or larger than the backlog. Overload drops the oldest pending audio.
    @discardableResult public func send(audio pcm: Data) -> Bool { child.write(pcm) }

    /// Ends the audio (EOF after queued audio is written); the child then emits `stopped` and `run` returns.
    public func finishInput() { child.closeInput() }

    /// Tears the child down (EOF, then SIGTERM, then SIGKILL) and waits until it is reaped.
    public func stop() async { await child.stop() }

    public var counters: RightyoChildProcess.Counters { child.counters }

    /// Consumes the child's events until it ends. Returns after a clean terminal session event and EOF; throws
    /// the first decode, consumer, dispatch or transport error. Either way the child is stopped and reaped.
    public func run() async throws -> Summary {
        var delivered = 0
        do {
            for try await line in child.lines {
                let event = try RightyoInputEvent.decode(line)
                if try await consumer.consume(event), event.type == "request" { delivered += 1 }
            }
            try await consumer.finish()
        } catch {
            await child.stop()
            throw error
        }
        let exit = await child.stop()
        return Summary(delivered: delivered, child: child.counters, exit: exit)
    }
}
#endif
