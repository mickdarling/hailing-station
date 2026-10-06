#if os(macOS)
// Ambient pipeline and its own-voice filter (#269) form one review boundary within the four-file budget.
// swiftlint:disable file_length
import Darwin
public import Foundation
import HailProtocol
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
        /// Own-voice rejection (#269): heard text this returns true for is never dispatched.
        public var isEcho: (@Sendable (String) -> Bool)?

        public init(executable: URL, config: URL, target: String, binding: String, connection: UUID,
                    allowSynthetic: Bool = false, timing: RightyoChildProcess.Timing = .init(),
                    isEcho: (@Sendable (String) -> Bool)? = nil) {
            (self.executable, self.config, self.target, self.binding) = (executable, config, target, binding)
            (self.connection, self.allowSynthetic, self.timing) = (connection, allowSynthetic, timing)
            self.isEcho = isEcho
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
                                            dispatcher: step, echoFilter: configuration.isEcho)
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
    /// Requests dropped as the host's own reply heard back (#269). A count only.
    public var echoDropped: Int { get async { await consumer.echoDropped } }

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
/// Own-voice rejection for ambient listening (#269 stage 1). Once the phone's mic stays open while a reply plays,
/// echo cancellation can leak some of the reply back into RightyO, which could then dispatch the assistant's own
/// words as a request. The host knows exactly what it is speaking, so an ambient request whose words largely
/// repeat a reply that is playing, or just finished, is dropped. Kept in memory only, never logged.
final class RecentSpokenReplies: Sendable {
    /// How long after a reply's estimated end of playback its words still count as "just said": phone buffering,
    /// network delay and RightyO's own endpointing all land after the last sample is sent.
    static let hold: Duration = .seconds(4)
    /// Fraction of a heard request's word pairs found in a reply that marks it as the reply's echo. High on purpose:
    /// Mick's follow-ups reuse the reply's phrases ("wait, the streaming relay is up?" scores 0.8), and an echo
    /// that slips through still faces RightyO's own decision, while a wrongly dropped request is just lost.
    static let echoThreshold = 0.85
    static let maxReplies = 8
    /// Shorter requests are never treated as echo: "stop", "wait" or a short quoted question must reach the
    /// assistant even when the reply itself contains the words.
    static let minimumWords = 5

    private struct Reply {
        var words: [String]
        var audioSeconds: Double = 0
        var firstAudio: ContinuousClock.Instant?
        var lastSeen: ContinuousClock.Instant
        var expires: ContinuousClock.Instant {
            let playEnd = firstAudio.map { $0.advanced(by: .seconds(audioSeconds)) } ?? lastSeen
            return max(playEnd, lastSeen).advanced(by: RecentSpokenReplies.hold)
        }
    }

    private let replies = Mutex<[UUID: Reply]>([:])
    private let now: @Sendable () -> ContinuousClock.Instant

    init(now: @escaping @Sendable () -> ContinuousClock.Instant = { ContinuousClock.now }) {
        self.now = now
    }

    /// Records a reply frame the host delivered: its text, or how much audio it has sent so far.
    func observe(_ frame: Frame) {
        let instant = now()
        replies.withLock { replies in
            switch frame.payload {
            case .text(let text):
                guard let reply = text.reply else { return }
                replies[reply.id, default: Reply(words: [], lastSeen: instant)].words = Self.words(text.text)
                replies[reply.id]?.lastSeen = instant
            case .audio(let audio):
                guard let reply = audio.reply, audio.codec == .pcm16, audio.sampleRate > 0, audio.channels > 0 else {
                    return
                }
                var entry = replies[reply.id] ?? Reply(words: [], lastSeen: instant)
                entry.firstAudio = entry.firstAudio ?? instant
                entry.audioSeconds += Double(audio.bytes.count) / Double(2 * audio.channels * audio.sampleRate)
                entry.lastSeen = instant
                replies[reply.id] = entry
            default: return
            }
            replies = replies.filter { $0.value.expires > instant }
            while replies.count > Self.maxReplies,
                  let oldest = replies.min(by: { $0.value.lastSeen < $1.value.lastSeen }) {
                replies.removeValue(forKey: oldest.key)
            }
        }
    }

    /// True when `heard` reads as the echo of a reply still playing or within `hold` of its end.
    func isEcho(_ heard: String) -> Bool {
        let instant = now()
        let heardWords = Self.words(heard)
        guard heardWords.count >= Self.minimumWords else { return false }
        return replies.withLock { replies in
            replies.values.contains { $0.expires > instant && Self.overlap(heardWords, $0.words) >= Self.echoThreshold }
        }
    }

    /// Lower-cased letter/digit runs, so punctuation and transcription casing don't matter.
    static func words(_ text: String) -> [String] {
        text.lowercased().split { !$0.isLetter && !$0.isNumber }.map(String.init)
    }

    /// Fraction of `heard`'s adjacent word pairs that also occur in `reply`.
    static func overlap(_ heard: [String], _ reply: [String]) -> Double {
        guard heard.count > 1, reply.count > 1 else { return 0 }
        let replyPairs = Set(zip(reply, reply.dropFirst()).map { "\($0) \($1)" })
        let heardPairs = zip(heard, heard.dropFirst()).map { "\($0) \($1)" }
        let found = heardPairs.filter { replyPairs.contains($0) }.count
        return Double(found) / Double(heardPairs.count)
    }
}
#endif
