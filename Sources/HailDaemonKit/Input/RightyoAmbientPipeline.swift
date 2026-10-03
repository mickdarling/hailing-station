#if os(macOS)
import Darwin
public import Foundation
import Synchronization

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
        // The daemon's own local-dispatch cap, as for `--reply-to`; in process there is no socket answer deadline.
        guard text.utf8.count <= LocalDispatchRequest.maxTextBytes else { throw RightyoInputError.capacity }
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

/// The child's stdout as JSONL lines (#203): read on its own thread, always to EOF so the child never wedges on a
/// full pipe. Each line is capped at `maxLineBytes`, and lines waiting to be taken at `maxQueuedBytes` in total;
/// either limit ends the stream fail-closed and the rest is discarded.
public struct RightyoChildLines: AsyncSequence, Sendable {
    public typealias Element = Data
    let stream: AsyncThrowingStream<Data, any Error>
    let queued: RightyoByteCount

    public struct AsyncIterator: AsyncIteratorProtocol {
        fileprivate var base: AsyncThrowingStream<Data, any Error>.AsyncIterator
        fileprivate let queued: RightyoByteCount
        public mutating func next() async throws -> Data? {
            let line = try await base.next()
            if let line { queued.withLock { $0 -= line.count } }
            return line
        }
    }

    public func makeAsyncIterator() -> AsyncIterator { AsyncIterator(base: stream.makeAsyncIterator(), queued: queued) }

    static func read(_ output: Int32, into lines: AsyncThrowingStream<Data, any Error>.Continuation,
                     queued: RightyoByteCount) {
        defer { close(output) }
        var buffer = [UInt8](repeating: 0, count: 16_384), line = Data(), open = true
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(output, $0.baseAddress, $0.count) }
            if count < 0, errno == EINTR { continue }
            guard count > 0 else {
                guard open else { return }
                do {
                    guard count == 0 else { throw RightyoChildError.transportLost }
                    if try line.isEmpty || emit(line, into: lines, queued: queued) { lines.finish() }
                } catch { lines.finish(throwing: error) }
                return
            }
            guard open else { continue }
            do { open = try split(buffer[..<count], line: &line, into: lines, queued: queued) } catch {
                lines.finish(throwing: error)
                open = false
            }
        }
    }

    /// Appends `bytes` to the pending line and emits each completed non-empty line. False once the reader is gone.
    private static func split(_ bytes: ArraySlice<UInt8>, line: inout Data,
                              into lines: AsyncThrowingStream<Data, any Error>.Continuation,
                              queued: RightyoByteCount) throws -> Bool {
        let parts = bytes.split(separator: 10, omittingEmptySubsequences: false)
        for (index, part) in parts.enumerated() {
            line.append(contentsOf: part)
            guard line.count <= RightyoChildProcess.maxLineBytes else { throw RightyoChildError.lineTooLong }
            guard index < parts.count - 1, !line.isEmpty else { continue }
            guard try emit(line, into: lines, queued: queued) else { return false }
            line = Data()
        }
        return true
    }

    /// False once the reader is gone; throws `backlog` past the queued-byte bound (the stream itself is unbounded).
    private static func emit(_ line: Data, into lines: AsyncThrowingStream<Data, any Error>.Continuation,
                             queued: RightyoByteCount) throws -> Bool {
        let fits = queued.withLock { total in
            guard total + line.count <= RightyoChildProcess.maxQueuedBytes else { return false }
            total += line.count
            return true
        }
        guard fits else { throw RightyoChildError.backlog }
        switch lines.yield(line) {
        case .dropped: throw RightyoChildError.backlog
        case .terminated: return false
        default: return true
        }
    }
}

/// The stderr byte count, shared with the drain thread without retaining the child.
final class RightyoByteCount: Sendable {
    private let count = Mutex(0)
    func withLock<Result: Sendable>(_ body: (inout Int) -> Result) -> Result { count.withLock { body(&$0) } }
}

/// What the piped audio is, as RightyO's required `--provenance` flag names it; stamped on every turn.
public enum RightyoAudioProvenance: String, Sendable {
    case liveMicrophone = "live-microphone", recordedFile = "recorded-file", causalReplay = "causal-replay"
    case synthetic
}
#endif
