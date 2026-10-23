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
    /// `routed` (#636) says the consumer's own route match chose this request's target: the owner named one of their
    /// voice routes. Only that decision may carry a request to a target other than the stream's own; without it, a
    /// different target is just refused. The default dispatches an un-routed request and refuses a routed one.
    func dispatch(_ request: LocalDispatchRequest, routed: Bool) async throws -> UUID?
}

extension RightyoAmbientDispatching {
    public func dispatch(_ request: LocalDispatchRequest, routed: Bool) async throws -> UUID? {
        guard !routed else { throw LocalDispatchRefusal.notAuthorized }
        return try await dispatch(request)
    }
}

/// Adapts the consumer's delivery step to a named-connection dispatch. A refusal that follows a completed
/// handoff (`ownershipLost`, `connectionLost`) still landed the prompt, so it is a receipt with a caveat.
struct RightyoAmbientDispatchStep: RightyoDispatching {
    let connection: UUID
    let dispatcher: any RightyoAmbientDispatching
    /// Acknowledges the admitted request (rightyo#105) before it is typed, or, for a routed one (#636), once it is
    /// handed off; never awaited, never throws.
    var acknowledge: (@Sendable () -> Void)?
    /// Shows the speaking device what it said (#318); awaited, so it precedes the acknowledgement, and the typing
    /// too unless the request is routed.
    var heard: (@Sendable () async -> Void)?
    func dispatch(text: String, target: String, binding: String) async throws -> RightyoDispatchReceipt {
        try await dispatch(text: text, target: target, binding: binding, routed: false)
    }

    /// A request the owner routed (#636) is shown and acknowledged only once handed off, so a route that refuses it
    /// never looks sent; the routing decision goes on to the listener, which alone may bind the route.
    func dispatch(
        text: String, target: String, binding: String, routed: Bool
    ) async throws -> RightyoDispatchReceipt {
        // The daemon's own local-dispatch cap, as for `--reply-to`; in process there is no socket answer deadline.
        guard text.utf8.count <= LocalDispatchRequest.maxTextBytes else { throw RightyoInputError.capacity }
        if !routed { await announce() }
        let request = LocalDispatchRequest(connection: connection, target: target, binding: binding, text: text)
        let receipt: RightyoDispatchReceipt
        do {
            receipt = RightyoDispatchReceipt(request: try await dispatcher.dispatch(request, routed: routed))
        } catch let refusal as LocalDispatchRefusal where refusal.handedOff {
            receipt = RightyoDispatchReceipt(request: nil, caveat: refusal.message)
        }
        if routed { await announce() }
        return receipt
    }

    private func announce() async {
        await heard?()
        acknowledge?()
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
        /// Called once per admitted `dismiss` (rightyo#98), in event order, with counts and tokens only.
        public var onDismiss: (@Sendable (RightyoDismissReceipt) -> Void)?
        /// Called once per admitted request just before it is typed (rightyo#105): the cue to acknowledge it.
        /// Echo-dropped, withdrawn and duplicate requests never reach it. It must return at once.
        public var onAcknowledge: (@Sendable (AmbientAckRequest) -> Void)?
        /// Give the child a control descriptor for spoken-reply reports (rightyo#124). Needs a RightyO that accepts
        /// `--control-fd`; off by default.
        public var replyControl = false
        /// Called instead of `onAcknowledge` for an admitted request RightyO marked `acknowledge: false` on a session
        /// that advertised `acknowledgement` (rightyo#132). Labels and numbers only. It must return at once.
        public var onAcknowledgementSkipped: (@Sendable (AmbientAckSkip) -> Void)?
        /// Called once per admitted request with its heard turn's text (#318), before it is acknowledged or typed, and
        /// awaited, so the device has the user's own words ahead of both. Echo-dropped, withdrawn and duplicate
        /// requests never reach it. The text goes only to the speaking device; it is never logged.
        public var onHeard: (@Sendable (String) async -> Void)?
        /// Called once per finalized turn RightyO decided not to send (#398), with its text, whether both its
        /// transcript and its decision carried the owner role, and (#434) a known guest's name for someone else's turn.
        /// Echo-matched turns never reach it. Text and name go only to the speaking device, within its chosen scope;
        /// neither is ever logged.
        public var onOverheard: (@Sendable (String, Bool, String?) async -> Void)?
        /// Called once per admitted request that is the owner's spoken mute (true) or unmute (false) (#404), instead
        /// of typing it: it is never acknowledged, shown or delivered to the target. It must return at once.
        public var onVoiceMute: (@Sendable (Bool) -> Void)?
        /// Called once per admitted request that is the owner's spoken media mode on (true) or off (#551), handled
        /// like `onVoiceMute`. It must return at once.
        public var onVoiceMedia: (@Sendable (Bool) -> Void)?
        /// Privacy mode (#735, internally duck), handled like `onVoiceMute`: called once per safety-set command in a
        /// transcript or request (`enter`; `stillRecording` when negated; `refused` from anyone but the owner;
        /// `unverified` from the owner role without a live voiceprint; `hint` for the owner's turn that starts with a
        /// command and goes on), once per RightyO `privacy` event (`exit`, `status`), and `unavailable` (below). Only
        /// when this is set are these turns privacy turns; then each is held back from the agent, and while privacy is
        /// on (the latest `reportDuck` said so) every request is. Without a control descriptor no child can take
        /// privacy, so an entry is refused, never typed. It must return at once.
        public var onVoiceDuck: (@Sendable (PrivacyCommand) -> Void)?
        /// Called when this child starts while privacy is wished for but its `started` did not advertise `duck`
        /// version 2 or higher (an older RightyO after a reload): it cannot keep privacy. The host never ends privacy
        /// for it (Mick, round 4: only the owner's exit does); it returns true when privacy is still on, and then
        /// `onVoiceDuck` hears `unavailable` and this child is refused: its run ends with `RightyoPrivacyRefusal`, so
        /// nothing records. Without this handler the child is refused too. It must return at once.
        public var onDuckUnsupported: (@Sendable () -> Bool)?
        /// The owner's allowlisted note destinations (#552); nil is off. A note to one is handed to
        /// `onVoiceDestination` with its destination key, target and words instead of being typed. It must return
        /// at once; the words go only to that destination, never to logs.
        public var destinations: VoiceDestinations?
        public var onVoiceDestination: (@Sendable (
            _ destination: String, _ target: VoiceDestinations.Destination, _ text: String) -> Void)?
        /// The owner's voice routes (#636); nil leaves every request on `target`. A request the owner addressed to a
        /// route that cannot take it is not typed anywhere; its reason goes to `onVoiceRouteRefused`, which must
        /// return at once.
        public var routing: RightyoVoiceRouting?
        public var onVoiceRouteRefused: (@Sendable (RightyoVoiceRouting.Refusal) -> Void)?
        /// Called when RightyO says the owner's voice is `unrecognized` on this input, or `recognized` again
        /// (rightyo#164), only on a session whose `started` advertised `owner_voice`, each state at most once and
        /// `recognized` only after `unrecognized`. It must return at once.
        public var onOwnerVoice: (@Sendable (String) -> Void)?
        /// Extra variables for the child (rightyo#172), `RIGHTYO_`-prefixed only.
        public var environment: [String: String] = [:]
        /// Launch the child already private (#735 S-2b), as the host does whenever privacy is on: RightyO's
        /// start-private option, privacy wished for from the first line, and a `started` that must confirm it
        /// (`"duck": {"version": 2 or later, "private": true}`) within `startDeadline`. One that does not is killed
        /// and the run throws `RightyoPrivacyRefusal.unconfirmedStart`: it is never admitted.
        public var startPrivate = false
        /// How long a child has to emit `started` while privacy is wished for before it is killed (and, until then, it
        /// hears no audio).
        public var startDeadline: TimeInterval = RightyoAmbientPipeline.defaultStartDeadline

        public init(executable: URL, config: URL, target: String, binding: String, connection: UUID,
                    allowSynthetic: Bool = false, timing: RightyoChildProcess.Timing = .init(),
                    isEcho: (@Sendable (String) -> Bool)? = nil,
                    onDismiss: (@Sendable (RightyoDismissReceipt) -> Void)? = nil,
                    onAcknowledge: (@Sendable (AmbientAckRequest) -> Void)? = nil) {
            (self.executable, self.config, self.target, self.binding) = (executable, config, target, binding)
            (self.connection, self.allowSynthetic, self.timing) = (connection, allowSynthetic, timing)
            (self.isEcho, self.onDismiss, self.onAcknowledge) = (isEcho, onDismiss, onAcknowledge)
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
    private let onDismiss: (@Sendable (RightyoDismissReceipt) -> Void)?
    private let onVoiceMute: (@Sendable (Bool) -> Void)?
    private let onVoiceMedia: (@Sendable (Bool) -> Void)?
    private let onVoiceDuck: (@Sendable (PrivacyCommand) -> Void)?
    private let duck: AmbientDuckControl
    /// The deadline for `started` while privacy is wished for (#735 S-2b), and whether this child was launched
    /// start-private (its `started` must then confirm `private`).
    private let startDeadline: TimeInterval
    private let startsPrivate: Bool
    private let onDuckUnsupported: (@Sendable () -> Bool)?
    private let onVoiceDestination: (@Sendable (String, VoiceDestinations.Destination, String) -> Void)?
    private let onVoiceRouteRefused: (@Sendable (RightyoVoiceRouting.Refusal) -> Void)?
    private let acknowledgement: AmbientAckRelay
    private let heard: AmbientHeardRelay
    private let overheard: AmbientOverheardRelay
    private let ownerVoice: AmbientOwnerVoiceRelay

    /// Validates the target and the executable before launching the child; a refusal launches nothing.
    public init(configuration: Configuration, dispatcher: any RightyoAmbientDispatching) throws {
        let session = "hail-\(UUID().uuidString.lowercased())"
        let relay = AmbientAckRelay(onAcknowledge: configuration.onAcknowledge,
                                    onSkip: configuration.onAcknowledgementSkipped)
        let heard = AmbientHeardRelay(onHeard: configuration.onHeard)
        let step = RightyoAmbientDispatchStep(connection: configuration.connection, dispatcher: dispatcher,
                                              acknowledge: { relay.fire() }, heard: { await heard.deliver() })
        let duck = AmbientDuckControl(startPrivate: configuration.startPrivate)
        let ducking: @Sendable () -> Bool = { duck.active }
        let duckActive = configuration.onVoiceDuck != nil ? ducking : nil
        consumer = try RightyoInputConsumer(host: nil, target: configuration.target, binding: configuration.binding,
                                            session: session, allowSynthetic: configuration.allowSynthetic,
                                            dispatcher: step, echoFilter: configuration.isEcho,
                                            mediaCommands: configuration.replyControl,
                                            destinations: configuration.destinations,
                                            routing: configuration.routing,
                                            duckActive: duckActive)
        let child = try RightyoChildProcess(executable: configuration.executable, config: configuration.config,
                                            session: session, timing: configuration.timing,
                                            replyControl: configuration.replyControl,
                                            env: configuration.environment, startPrivate: configuration.startPrivate)
        (self.child, self.session) = (child, session)
        onDismiss = configuration.onDismiss
        (onVoiceMute, onVoiceMedia) = (configuration.onVoiceMute, configuration.onVoiceMedia)
        onVoiceDuck = configuration.onVoiceDuck
        (self.duck, onDuckUnsupported) = (duck, configuration.onDuckUnsupported)
        (startDeadline, startsPrivate) = (configuration.startDeadline, configuration.startPrivate)
        onVoiceDestination = configuration.onVoiceDestination
        onVoiceRouteRefused = configuration.onVoiceRouteRefused
        acknowledgement = relay
        self.heard = heard
        overheard = AmbientOverheardRelay(onOverheard: configuration.onOverheard, isEcho: configuration.isEcho)
        ownerVoice = AmbientOwnerVoiceRelay(onOwnerVoice: configuration.onOwnerVoice)
    }

    /// Hands one raw mono 16 kHz s16le chunk to the child without blocking; false once input has closed or for
    /// a chunk that is empty, odd-length or larger than the backlog. Overload drops the oldest pending audio.
    /// While privacy is wished for and this child has not yet shown it keeps it (#735 S-2b round 3: a `started` that
    /// confirms `private` for a start-private child, or a v2 child that took `{"duck":true}`), the chunk is dropped,
    /// never written, and this returns true: the child hears no private audio, and the stream is not ended for it.
    @discardableResult public func send(audio pcm: Data) -> Bool {
        guard duck.mayHearAudio else { return true }
        return child.write(pcm)
    }

    /// Whether audio now reaches the child (#735 S-2b; tests).
    var hearsAudio: Bool { duck.mayHearAudio }
    /// Whether haild has read the child's first `started` (#735; tests): a privacy wish before it is kept, not written.
    var childStarted: Bool { duck.started }

    /// Reports the assistant's spoken reply on this stream's device (rightyo#124); false when reply control is off
    /// or the report was dropped. Never blocks.
    @discardableResult public func reportReply(_ phase: RightyoReplyPhase, asked: Bool = false) -> Bool {
        child.reportReply(phase, asked: asked)
    }

    /// Sets media mode in this stream's RightyO (#551) over the same control descriptor; false when reply control is
    /// off or the line was dropped. Never blocks.
    @discardableResult public func reportMedia(_ on: Bool) -> Bool { child.reportMedia(on) }

    /// Sets privacy mode (#735, internally duck) in this stream's RightyO over the same control descriptor; true only
    /// when the child's `started` advertised `duck` version 2 or higher and the line was written. An older RightyO
    /// still transcribes while ducked (v1) or skips the line, so it is never written one and this is false: the host
    /// then never claims privacy is on (fail closed).
    /// Asked before `started`, the wish is kept and written once a child that advertised it starts. Never blocks.
    @discardableResult public func reportDuck(_ on: Bool) -> Bool {
        duck.report(on) { [child] on in child.reportDuck(on) }
    }

    /// Ends the audio (EOF after queued audio is written); the child then emits `stopped` and `run` returns.
    public func finishInput() { child.closeInput() }

    /// Tears the child down (EOF, then SIGTERM, then SIGKILL) and waits until it is reaped.
    public func stop() async { await child.stop() }

    /// The same teardown with short graces (#366): EOF, SIGTERM after `grace`, SIGKILL after `grace` more. For a
    /// retired child that must make room for a new one at once; a dispatch it has not yet made is lost.
    public func stop(grace: TimeInterval) async { await child.stop(eofGrace: grace, termGrace: grace) }

    public var counters: RightyoChildProcess.Counters { child.counters }
    /// Requests dropped as the host's own reply heard back (#269). A count only.
    public var echoDropped: Int { get async { await consumer.echoDropped } }
    /// Requests dropped because the speaker's dismissal had withdrawn them (rightyo#98). A count only.
    public var withdrawnDropped: Int { get async { await consumer.withdrawnDropped } }

    /// Consumes the child's events until it ends. Returns after a clean terminal session event and EOF; throws
    /// the first decode, consumer, dispatch or transport error. Either way the child is stopped and reaped.
    public func run() async throws -> Summary {
        let deadline = armStartDeadline()
        defer { deadline?.cancel() }
        var delivered = 0
        do {
            for try await line in child.lines {
                let event = try RightyoInputEvent.decode(line)
                let relayed = observeBeforeConsuming(event)
                if try await consumer.consume(event), event.type == "request" { delivered += 1 }
                // Only after the consumer admitted the line: an invalid one has already ended the stream.
                if relayed { await overheard.observe(event) }
                ownerVoice.observe(event)
                try await observeStarted(event, line: line)
                // A newly admitted `dismiss` delivers nothing and leaves its receipt; a replayed one leaves none.
                if event.type == "dismiss", let receipt = await consumer.lastDismissal { onDismiss?(receipt) }
                // A newly admitted voice mute (#404) is handed to the host instead of being typed.
                if event.type == "request", let command = await consumer.lastVoiceMute {
                    onVoiceMute?(command == .mute)
                }
                if event.type == "request", let command = await consumer.lastVoiceMedia {
                    onVoiceMedia?(command == .on)
                }
                if let command = await consumer.lastPrivacy { onVoiceDuck?(command) }
                if event.type == "request", let note = await consumer.lastVoiceDestination {
                    onVoiceDestination?(note.destination, note.target, note.text)
                }
                if event.type == "request", let refusal = await consumer.lastRouteRefusal {
                    onVoiceRouteRefused?(refusal)
                }
            }
            try await consumer.finish()
            try duck.checkStarted()
        } catch {
            await child.stop()
            throw duck.expired ? RightyoPrivacyRefusal.unconfirmedStart : error
        }
        let exit = await child.stop()
        return Summary(delivered: delivered, child: child.counters, exit: exit)
    }
}

/// Privacy mode (#735) in the event loop, beside the type so its body stays within the length limit.
extension RightyoAmbientPipeline {
    /// The events that carry or decide heard words: while privacy is on none of them reaches a relay.
    static func carriesWords(_ event: RightyoInputEvent) -> Bool {
        ["transcript", "attention", "request"].contains(event.type)
    }

    /// Hands `event` to the acknowledgement and heard relays; false, relaying nothing, for words that still arrive
    /// while privacy is on (#735: the child has not read the line yet). Those reach only the consumer, which keeps
    /// hashes and holds every request; the overheard relay must then skip them too.
    private func observeBeforeConsuming(_ event: RightyoInputEvent) -> Bool {
        guard !(duck.active && Self.carriesWords(event)) else { return false }
        acknowledgement.observe(event, readAt: .now)
        heard.observe(event)
        return true
    }

    /// A child's `started` that cannot keep the privacy wished for (#735): a start-private child (S-2b) that did not
    /// confirm it, or one launched before privacy came on that did not advertise `duck` v2 while the host is still
    /// private. It is killed at once (SIGTERM then SIGKILL, no grace), `unavailable` is said, and its run throws
    /// `RightyoPrivacyRefusal`: never admitted, nothing records, and privacy itself stays on.
    private func observeStarted(_ event: RightyoInputEvent, line: Data) async throws {
        guard event.type == "session", event.phase == "started",
              duck.observe(started: line, write: { [child] on in child.reportDuck(on) }) == .refused else { return }
        guard startsPrivate || onDuckUnsupported?() ?? true else {
            duck.release()
            return
        }
        await child.stop(eofGrace: 0, termGrace: 0)
        onVoiceDuck?(.unavailable)
        throw startsPrivate ? RightyoPrivacyRefusal.unconfirmedStart : RightyoPrivacyRefusal.unsupportedChild
    }

    /// A child that has not emitted `started` by its deadline while privacy is wished for (launched start-private, or
    /// privacy entered while it was starting) is killed and `unavailable` is said; it never heard any audio, and the
    /// run then throws `RightyoPrivacyRefusal.unconfirmedStart`. Nil for a child without privacy handling.
    private func armStartDeadline() -> Task<Void, Never>? {
        guard onVoiceDuck != nil || startsPrivate else { return nil }
        return Task { [duck, child, onVoiceDuck, startDeadline] in
            try? await Task.sleep(for: .seconds(startDeadline))
            guard !Task.isCancelled, duck.expire() else { return }
            await child.stop(eofGrace: 0, termGrace: 0)
            onVoiceDuck?(.unavailable)
        }
    }

    /// Ten seconds: far beyond a healthy RightyO's start, short enough that a wedged one is not left holding the
    /// stream while the owner believes it is listening privately.
    public static let defaultStartDeadline: TimeInterval = 10
}

/// A child refused because it cannot keep the privacy the host is in (#735 round 4): its run ends with this.
/// `unsupportedChild`: no `duck` v2 at `started`; `unconfirmedStart` (S-2b): launched start-private and its `started`
/// did not confirm `"private": true`, or did not come within the deadline. Content-free.
public enum RightyoPrivacyRefusal: Error, Sendable, Equatable { case unsupportedChild, unconfirmedStart }

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
        /// When this reply's audio is estimated to start playing: its first frame, or later if it queued behind a
        /// reply still playing (the phone plays replies one after another).
        var firstAudio: ContinuousClock.Instant?
        var lastSeen: ContinuousClock.Instant
        var playEnd: ContinuousClock.Instant? { firstAudio.map { $0.advanced(by: .seconds(audioSeconds)) } }
        var expires: ContinuousClock.Instant {
            let playEnd = playEnd ?? lastSeen
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
                if entry.firstAudio == nil {
                    let queuedBehind = replies.values.compactMap(\.playEnd).max()
                    entry.firstAudio = max(instant, queuedBehind ?? instant)
                }
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
            // A text-only reply is never spoken, so its words cannot echo.
            replies.values.contains {
                $0.firstAudio != nil && $0.expires > instant && Self.overlap(heardWords, $0.words) >= Self.echoThreshold
            }
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
/// Carries the acknowledgement from the pipeline's read loop to its dispatch step (rightyo#105): armed with the
/// request line just read, fired by the step only once the consumer has admitted it (after the echo, withdrawal
/// and duplicate checks) and before it is typed. The persona sticks across turns that say no name.
/// Gating (rightyo#132): on a session whose `started` advertised `acknowledgement`, a request marked
/// `acknowledge: false` arms a skip instead, so `fire` reports it to `onSkip` and plays nothing. A missing field,
/// or one on a session that did not advertise gating, acknowledges as before.
final class AmbientAckRelay: Sendable {
    private struct Armed {
        let text: String, endMs: Int, emittedAtMs: Int, readAt: ContinuousClock.Instant
        let skip: AmbientAckSkip?
    }
    private struct State {
        var addressing = RightyoAddressing(spellings: [:])
        var gated = false
        var persona: String?
        var armed: Armed?
    }
    private let state = Mutex(State())
    private let onAcknowledge: (@Sendable (AmbientAckRequest) -> Void)?
    private let onSkip: (@Sendable (AmbientAckSkip) -> Void)?

    init(onAcknowledge: (@Sendable (AmbientAckRequest) -> Void)?, onSkip: (@Sendable (AmbientAckSkip) -> Void)? = nil) {
        (self.onAcknowledge, self.onSkip) = (onAcknowledge, onSkip)
    }

    func observe(_ event: RightyoInputEvent, readAt: ContinuousClock.Instant) {
        guard onAcknowledge != nil else { return }
        state.withLock { state in
            if event.type == "session", event.phase == "started" {
                state.addressing = RightyoAddressing(event.addressing)
                state.gated = event.acknowledgement != nil
            }
            if event.type == "request", let turn = event.turn {
                let skip = state.gated && event.acknowledge == .bool(false)
                    ? AmbientAckSkip(followUp: event.decision?.followUp == true, confidence: event.decision?.confidence)
                    : nil
                // Raw times only: this line is not validated yet, so nothing is computed from them here.
                state.armed = Armed(text: turn.text, endMs: turn.endMs, emittedAtMs: event.emittedAtMs, readAt: readAt,
                                    skip: skip)
            } else {
                state.armed = nil
            }
        }
    }

    func fire() {
        guard let onAcknowledge else { return }
        let fired = state.withLock { state -> Outcome? in
            guard let armed = state.armed else { return nil }
            state.armed = nil
            state.persona = state.addressing.persona(in: armed.text) ?? state.persona
            if let skip = armed.skip { return .skipped(skip) }
            // Fired only for an admitted request, whose validation bounds both times; still never trap.
            let (delta, overflow) = armed.emittedAtMs.subtractingReportingOverflow(armed.endMs)
            return .acknowledge(AmbientAckRequest(persona: state.persona, rightyoMs: overflow ? 0 : max(0, delta),
                                                  readAt: armed.readAt))
        }
        switch fired {
        case .acknowledge(let request): onAcknowledge(request)
        case .skipped(let skip): onSkip?(skip)
        case nil: break
        }
    }

    private enum Outcome { case acknowledge(AmbientAckRequest), skipped(AmbientAckSkip) }
}

/// The admitted request's heard turn (#318), held from the line's read to its delivery step, like the acknowledgement:
/// set by a `request` line, cleared by any other, taken once. Echo-dropped, withdrawn and duplicate requests never
/// reach the delivery step, so they are never shown. The text is never logged.
final class AmbientHeardRelay: Sendable {
    private let held = Mutex<String?>(nil)
    private let onHeard: (@Sendable (String) async -> Void)?

    init(onHeard: (@Sendable (String) async -> Void)?) { self.onHeard = onHeard }

    func observe(_ event: RightyoInputEvent) {
        guard onHeard != nil else { return }
        held.withLock { $0 = event.type == "request" ? event.turn?.text : nil }
    }

    func deliver() async {
        guard let onHeard, let text = held.withLock({ held in defer { held = nil }; return held }) else { return }
        await onHeard(text)
    }
}

/// Owner voice status (rightyo#164, rightyo#172). Only on a session whose `started` advertised `owner_voice` as an
/// object with a numeric `threshold_s`; then `unrecognized` is reported at most once, and `recognized` at most once and
/// only after it. Anything else (unadvertised, out of order, a replayed line) is ignored, never refused: it is status.
/// Only the first `started` sets it up: the consumer admits an identical replay, which must not reset what was reported.
final class AmbientOwnerVoiceRelay: Sendable {
    private struct State {
        var started = false
        var advertised = false
        var reported: String?
    }
    private let state = Mutex(State())
    private let onOwnerVoice: (@Sendable (String) -> Void)?

    init(onOwnerVoice: (@Sendable (String) -> Void)?) { self.onOwnerVoice = onOwnerVoice }

    func observe(_ event: RightyoInputEvent) {
        guard let onOwnerVoice else { return }
        if event.type == "session", event.phase == "started" {
            state.withLock { state in
                guard !state.started else { return }
                (state.started, state.advertised) = (true, Self.advertises(event.ownerVoice))
            }
            return
        }
        guard event.type == "owner_voice", let next = event.state else { return }
        let report = state.withLock { state -> Bool in
            guard state.advertised else { return false }
            switch (state.reported, next) {
            case (nil, "unrecognized"), ("unrecognized", "recognized"):
                state.reported = next
                return true
            default:
                return false
            }
        }
        if report { onOwnerVoice(next) }
    }

    /// RightyO's documented advertisement: an object with a numeric `threshold_s`.
    static func advertises(_ value: JSONValue?) -> Bool {
        guard case .object(let object) = value else { return false }
        switch object["threshold_s"] {
        case .integer?, .number?: return true
        default: return false
        }
    }
}

/// Privacy mode in one child (#735, internally duck): written only once the child's admitted `started` advertised a
/// top-level `duck` object with an integer `version` of 2 or higher (rightyo S-1, "keeps nothing"); a v1 child still
/// transcribes while ducked, so it counts as not advertising it. Until `started`, the latest wish is kept
/// and written then; a child that did not advertise it is never written a duck line, and a wish it cannot take is
/// dropped and reported, so the host ends duck mode rather than claim it. Under one lock, so a wish and the `started`
/// that answers it cannot cross. `active` is the host's latest wish as this child holds it: the owner is ducking.
/// Started private (#735 S-2b), the wish is on from the first line and `started` must confirm `"private": true`.
final class AmbientDuckControl: Sendable {
    /// What a child's first `started` meant: `kept`, or `refused` when privacy is wished for and this child cannot
    /// keep it (launched start-private without confirming it, or without `duck` v2): it must be killed.
    enum Started: Equatable { case kept, refused }
    private struct State {
        var started = false, advertised = false, wanted = false, mustConfirm = false, expired = false
        /// This child has shown it keeps privacy: a confirmed start-private `started`, or a v2 child that took
        /// `{"duck":true}`. Until then, while privacy is wished for, it hears no audio.
        var keeps = false
    }
    private let state: Mutex<State>

    init(startPrivate: Bool = false) {
        state = Mutex(State(wanted: startPrivate, mustConfirm: startPrivate))
    }

    var active: Bool { state.withLock { $0.wanted } }
    /// Audio may reach the child: privacy is not wished for, or the child has shown it keeps it (#735 S-2b round 3).
    var mayHearAudio: Bool { state.withLock { !$0.wanted || $0.keeps } }

    /// The host says privacy already ended for a child that could not keep it: it runs on, public.
    func release() { state.withLock { $0.wanted = false } }
    /// The start deadline passed before `started` (#735 S-2b).
    var expired: Bool { state.withLock { $0.expired } }
    /// The child's first `started` was read (tests).
    var started: Bool { state.withLock { $0.started } }

    /// Ends the wait for `started` at the deadline: true when it had not come (the child must be killed); a later
    /// `started` is then ignored, and the wish stays on.
    func expire() -> Bool {
        state.withLock { state in
            guard state.wanted || state.mustConfirm, !state.started else { return false }
            (state.started, state.expired) = (true, true)
            return true
        }
    }

    /// Throws `unconfirmed` when the deadline passed: a run that otherwise ended cleanly is still a refusal.
    func checkStarted() throws {
        if expired { throw RightyoPrivacyRefusal.unconfirmedStart }
    }

    /// Sets the host's wish; true when this child takes it: written now to a child that advertised v2, or kept for
    /// one not yet started, which takes it at `started` or is refused then (`observe`).
    func report(_ on: Bool, write: (Bool) -> Bool) -> Bool {
        state.withLock { state in
            state.wanted = on
            guard state.started else { return true }
            let taken = state.advertised && write(on)
            // A v2 child keeps privacy only once it has taken the line; a failed write withholds audio (fail closed).
            if on { state.keeps = taken }
            return taken
        }
    }

    /// Records the child's first `started`. A child that cannot keep the privacy wished for is never written and stays
    /// wished private (its words stay held) until it is killed. A confirmed start-private one the host no longer wants
    /// private is written off.
    func observe(started line: Data, write: (Bool) -> Bool) -> Started {
        let (advertised, confirmed) = (Self.advertises(line), Self.confirmsPrivate(line))
        return state.withLock { state in
            guard !state.started else { return .kept }
            state.started = true
            if state.mustConfirm, !confirmed {
                state.wanted = true
                return .refused
            }
            state.advertised = advertised
            if state.mustConfirm {
                state.keeps = true
                if !state.wanted { _ = write(false) }
                return .kept
            }
            guard state.wanted else { return .kept }
            guard advertised else { return .refused }
            state.keeps = write(true)
            return .kept
        }
    }

    /// Whether a `started` line says the child started private (#735 S-2b): a `duck` advertisement of version 2 or
    /// higher whose `private` is the boolean true. Nothing else confirms it.
    static func confirmsPrivate(_ line: Data) -> Bool {
        guard advertises(line),
              let object = try? JSONDecoder().decode([String: JSONValue].self, from: line),
              case .object(let duck)? = object["duck"], case .bool(true)? = duck["private"] else { return false }
        return true
    }

    /// Whether a `started` line carries a top-level `duck` object of version 2 or higher.
    static func advertises(_ line: Data) -> Bool {
        guard let object = try? JSONDecoder().decode([String: JSONValue].self, from: line) else { return false }
        return (RightyoInputEvent.privacyVersion(object["duck"]) ?? 0) >= 2
    }
}

/// Turns heard but not sent (#398): a finalized transcript's text and role are held, bounded and in memory only, until
/// RightyO decides the turn. An `attention` that forms no request reports it once; one that names a request, or the
/// request itself, drops it (that turn is shown as `ambient_heard`). Owner means both records carried `owner`, as the
/// consumer's own rule. Echo-matched turns (the assistant's own reply heard back) are never reported.
/// Named guests (#434): only on a session whose `started` advertised `speaker_names` in its documented shape, a
/// non-owner transcript's `speaker_name` that `guestName` accepts is held with it, and reported only if the turn is
/// not the owner's and its decision does not say owner either (records that disagree are uncertain, so unnamed);
/// anything else is reported unnamed, as "someone".
final class AmbientOverheardRelay: Sendable {
    static let maxHeld = 32
    private struct Held { let text: String, owner: Bool, name: String? }
    private struct State {
        var held: [(String, Held)] = []
        var naming = false
    }
    private let state = Mutex(State())
    private let onOverheard: (@Sendable (String, Bool, String?) async -> Void)?
    private let isEcho: (@Sendable (String) -> Bool)?

    init(onOverheard: (@Sendable (String, Bool, String?) async -> Void)?, isEcho: (@Sendable (String) -> Bool)?) {
        (self.onOverheard, self.isEcho) = (onOverheard, isEcho)
    }

    func observe(_ event: RightyoInputEvent) async {
        guard let onOverheard else { return }
        switch event.type {
        case "session":
            if event.phase == "started" { state.withLock { $0.naming = Self.advertisesNames(event.speakerNames) } }
        case "transcript":
            guard let turn = event.turn else { return }
            state.withLock { state in
                guard !state.held.contains(where: { $0.0 == turn.utteranceId }) else { return }
                let owner = turn.role == "owner"
                let name = state.naming && !owner ? Self.guestName(event.speakerName) : nil
                state.held.append((turn.utteranceId, Held(text: turn.text, owner: owner, name: name)))
                if state.held.count > Self.maxHeld { state.held.removeFirst(state.held.count - Self.maxHeld) }
            }
        case "attention", "request":
            guard let utterance = event.utteranceId ?? event.turn?.utteranceId,
                  let turn = take(utterance), event.type == "attention", event.requestId == nil,
                  isEcho?(turn.text) != true else { return }
            let (owner, decidedOwner) = (turn.owner && event.decision?.role == "owner", event.decision?.role == "owner")
            await onOverheard(turn.text, owner, owner || decidedOwner ? nil : turn.name)
        default: break
        }
    }

    /// RightyO's documented `speaker_names` advertisement (rightyo#171): an object with a positive integer
    /// `max_scalars`. Anything else (`false`, `{}`, a string) does not turn naming on.
    static func advertisesNames(_ value: JSONValue?) -> Bool {
        guard case .object(let object) = value, case .integer(let limit)? = object["max_scalars"] else { return false }
        return limit > 0
    }

    /// A guest's display name a device may show (#434), or nil to show "someone": a string the protocol accepts
    /// (`AmbientOverheard.name`: so a frame never fails to encode; ZWJ or ZWNJ names fall back here), with no
    /// character the sanitizer's hidden-character rule refuses, at least one visible letter, number, punctuation
    /// mark or symbol (so a name of fillers, blanks or combining marks alone is never shown), and never "You" in any
    /// case, which the device keeps for the owner.
    static func guestName(_ value: JSONValue?) -> String? {
        guard case .string(let raw) = value, let name = AmbientOverheard.name(raw),
              Sanitizer.firstHiddenCharacterClass(in: name) == nil,
              name.unicodeScalars.contains(where: Self.isVisible),
              name.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare("You") != .orderedSame
        else { return nil }
        return name
    }

    private static func isVisible(_ scalar: Unicode.Scalar) -> Bool {
        guard !scalar.properties.isDefaultIgnorableCodePoint, scalar.value != 0x2800 else { return false }
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter,
             .decimalNumber, .letterNumber, .otherNumber,
             .connectorPunctuation, .dashPunctuation, .openPunctuation, .closePunctuation, .initialPunctuation,
             .finalPunctuation, .otherPunctuation, .mathSymbol, .currencySymbol, .modifierSymbol, .otherSymbol:
            return true
        default:
            return false
        }
    }

    private func take(_ utterance: String) -> Held? {
        state.withLock { state in
            guard let index = state.held.firstIndex(where: { $0.0 == utterance }) else { return nil }
            return state.held.remove(at: index).1
        }
    }
}
#endif
