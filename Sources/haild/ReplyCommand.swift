import Darwin
import Foundation
import HailDaemonKit
import HailProtocol
import Network

// Parsing, static PCM submission, and the streaming vbsay adapter stay together to share reply identity.
// swiftlint:disable file_length

enum ReplyCommandError: Error, CustomStringConvertible {
    case usage
    case invalid(String)

    var description: String {
        switch self {
        case .usage: "invalid reply arguments"
        case .invalid(let message): message
        }
    }
}

private struct ReplyOptions {
    var target = ""
    var host = ProcessInfo.processInfo.hostName
    var text: String?
    var pcm16: URL?
    var say: String?
    var requestID: UUID?
    var rendererOutputRoot: URL?
    var sampleRate = 24_000
    var socket = LocalReplyEndpoint.standardSocket()

    mutating func apply(_ flag: String, value: String) throws {
        if flag == "--renderer-output-root" {
            rendererOutputRoot = URL(fileURLWithPath: value, isDirectory: true)
            return
        }
        switch flag {
        case "--host": host = value
        case "--text": text = value
        case "--pcm16": pcm16 = URL(fileURLWithPath: value)
        case "--say":
            say = value
            text = value
        case "--sample-rate":
            guard let rate = Int(value), PayloadLimits.sampleRates.contains(rate) else {
                throw ReplyCommandError.invalid("sample rate must be 8000...96000 Hz")
            }
            sampleRate = rate
        case "--socket": socket = URL(fileURLWithPath: value)
        case "--request":
            requestID = try parseReplyRequest(value)
        default: throw ReplyCommandError.usage
        }
    }
}

private func parseReplyRequest(_ value: String) throws -> UUID {
    guard let id = UUID(uuidString: value) else { throw ReplyCommandError.invalid("request must be a UUID") }
    return id
}

private struct PCMReplyContext {
    var sampleRate: Int
    var streamID: UUID
    var descriptor: ReplyDescriptor
    var socket: URL
    var frameLimit: Int
}

func reply(_ arguments: ArraySlice<String>) async throws {
    let options = try replyOptions(arguments)
    let rendererRoot = options.rendererOutputRoot ?? FileManager.default.temporaryDirectory
    if options.say != nil { try OwnedReplyRenderer.validateOutputRoot(rendererRoot) }
    let streamID = (options.pcm16 != nil || options.say != nil) ? UUID() : nil
    let descriptor = ReplyDescriptor(
        id: UUID(), hostID: options.host, targetID: options.target, audioStreamID: streamID,
        requestID: options.requestID
    )
    let audioFrameLimit = LocalReplyEndpoint.maxFramesPerMinute - (options.text == nil ? 0 : 1)
    var frames = 0
    var deliveries = 0
    if let text = options.text {
        let frame = Frame(
            timestamp: replyTimestamp(), target: options.target, source: options.host,
            payload: .text(TextPayload(text: text, reply: descriptor))
        )
        deliveries += try await ReplyClient.submit(frame, socketURL: options.socket)
        frames += 1
    }
    if let file = options.pcm16, let streamID {
        let context = PCMReplyContext(
            sampleRate: options.sampleRate, streamID: streamID, descriptor: descriptor,
            socket: options.socket, frameLimit: audioFrameLimit
        )
        let result = try await sendPCM(file, context: context)
        frames += result.frames
        deliveries += result.deliveries
    }
    if let spoken = options.say, let streamID {
        let context = PCMReplyContext(
            sampleRate: options.sampleRate, streamID: streamID, descriptor: descriptor,
            socket: options.socket, frameLimit: audioFrameLimit
        )
        let result = try await streamVBSay(spoken, outputRoot: rendererRoot, context: context)
        frames += result.frames
        deliveries += result.deliveries
    }
    let frameWord = frames == 1 ? "frame" : "frames"
    let deliveryWord = deliveries == 1 ? "delivery" : "deliveries"
    print("submitted \(frames) \(frameWord); \(deliveries) terminal \(deliveryWord)")
}

private func replyOptions(_ arguments: ArraySlice<String>) throws -> ReplyOptions {
    guard let target = arguments.first, !target.isEmpty else { throw ReplyCommandError.usage }
    var options = ReplyOptions(target: target)
    var rest = arguments.dropFirst()
    while let flag = rest.popFirst() {
        guard let value = rest.popFirst() else { throw ReplyCommandError.usage }
        try options.apply(flag, value: value)
    }
    guard !options.host.isEmpty, options.text != nil || options.pcm16 != nil,
          options.pcm16 == nil || options.say == nil else {
        throw ReplyCommandError.usage
    }
    if let text = options.text, text.utf8.count > PayloadLimits.maxTextBytes {
        throw ReplyCommandError.invalid("text exceeds \(PayloadLimits.maxTextBytes) bytes")
    }
    if options.say != nil, options.sampleRate != 24_000 {
        throw ReplyCommandError.invalid("vbsay output is fixed at 24000 Hz")
    }
    if options.rendererOutputRoot != nil, options.say == nil { throw ReplyCommandError.usage }
    return options
}

private func sendPCM(
    _ url: URL, context: PCMReplyContext
) async throws -> (frames: Int, deliveries: Int) {
    try await sendPCMFile(
        url, context: context, sequence: 0, marksFinal: true
    )
}

private func sendPCMFile(
    _ url: URL, context: PCMReplyContext, sequence startingSequence: Int, marksFinal: Bool, renderedAudio: Bool = false
) async throws -> (frames: Int, deliveries: Int) {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
    let segmentBytes = 48 * 1_024
    let segments = (size + segmentBytes - 1) / segmentBytes
    let usableLimit = context.frameLimit - (marksFinal ? 0 : 1)
    guard size > 0, size.isMultiple(of: 2),
          startingSequence + segments <= usableLimit else {
        throw ReplyCommandError.invalid("PCM16 reply exceeds the endpoint frame budget")
    }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var current = try handle.read(upToCount: segmentBytes) ?? Data()
    var sequence = startingSequence
    var deliveries = 0
    while !current.isEmpty {
        let next = try handle.read(upToCount: segmentBytes) ?? Data()
        let payload = AudioPayload(
            codec: .pcm16, sampleRate: context.sampleRate, channels: 1, sequence: sequence,
            streamID: context.streamID, isFinal: marksFinal && next.isEmpty,
            bytes: current, reply: context.descriptor
        )
        let frame = Frame(
            timestamp: replyTimestamp(), target: context.descriptor.targetID, source: context.descriptor.hostID,
            payload: .audio(payload)
        )
        if renderedAudio {
            deliveries += try await submitSpeechAudio(frame, socketURL: context.socket)
        } else {
            deliveries += try await ReplyClient.submit(frame, socketURL: context.socket)
        }
        sequence += 1
        current = next
    }
    return (sequence - startingSequence, deliveries)
}

// Generation, incremental publication, finalization, and child cleanup form one failure boundary.
private func streamVBSay(
    _ text: String, outputRoot: URL, context: PCMReplyContext
) async throws -> (frames: Int, deliveries: Int) {
    let renderer = try OwnedReplyRenderer(
        text: text, outputRoot: outputRoot, environment: ProcessInfo.processInfo.environment
    )
    do {
        let result = try await withTaskCancellationHandler {
            try await publishRenderer(renderer, context: context)
        } onCancel: {
            renderer.cancel()
        }
        renderer.retire(cancel: false)
        try await renderer.waitForCleanup()
        return result
    } catch {
        renderer.retire(cancel: true)
        await renderer.waitForCancellationSignals()
        // The CLI must remain alive to retain reaping/cleanup ownership. This async suspension is not
        // a fixed kernel deadline; whole-job deadline supervision belongs to the separate #177 owner.
        do { try await renderer.waitForCleanup() } catch OwnedReplyRendererError.cleanupDeferred {
            throw speechReplyFailure(error, cleanupDeferred: true)
        }
        throw speechReplyFailure(error, cleanupDeferred: false)
    }
}

private func speechReplyFailure(_ error: any Error, cleanupDeferred: Bool) -> any Error {
    if error is CancellationError { return OwnedReplyRendererError.cancelled }
    if error is OwnedReplyRendererError { return error }
    if let command = error as? ReplyCommandError {
        return cleanupDeferred ? ReplyCommandError.invalid("\(command); owned output cleanup deferred") : command
    }
    return OwnedReplyRendererError.invalidAudio
}

private func submitSpeechAudio(_ frame: Frame, socketURL: URL) async throws -> Int {
    do { return try await ReplyClient.submit(frame, socketURL: socketURL) } catch {
        if error is CancellationError { throw error }
        // Local refusal/lost acknowledgement remains the primary category, not a renderer cleanup
        // failure. Never forward raw endpoint/NW errors or restart the whole accepted-text command.
        throw OwnedReplyRendererError.publicationFailed
    }
}

// Streaming and terminal-marker recovery share their existing single publication failure boundary.
private func publishRenderer(
    _ renderer: OwnedReplyRenderer, context: PCMReplyContext
) async throws -> (frames: Int, deliveries: Int) {
    let directory = renderer.outputDirectory
    var observed: [URL: Int] = [:]
    var sent: Set<URL> = []
    var sequence = 0, deliveries = 0
    do {
        while renderer.isRunning {
            let result = try await sendStableVBSayFiles(
                in: directory, observed: &observed, sent: &sent, sequence: sequence,
                context: context
            )
            sequence += result.frames
            deliveries += result.deliveries
            try await Task.sleep(for: .milliseconds(100))
        }
        try await renderer.requireSuccessfulExit()
        // A file can complete between the final poll and process exit; two passes establish stability.
        for _ in 0..<2 {
            let result = try await sendStableVBSayFiles(
                in: directory, observed: &observed, sent: &sent, sequence: sequence,
                context: context
            )
            sequence += result.frames
            deliveries += result.deliveries
        }
        guard !sent.isEmpty else { throw ReplyCommandError.invalid("vbsay produced no PCM audio") }
    } catch {
        if sequence > 0, sequence < context.frameLimit {
            _ = try? await sendFinalPCM(sequence: sequence, context: context)
        }
        throw error
    }
    deliveries += try await sendFinalPCM(sequence: sequence, context: context)
    return (sequence + 1, deliveries)
}

private func sendFinalPCM(sequence: Int, context: PCMReplyContext) async throws -> Int {
    let final = AudioPayload(
        codec: .pcm16, sampleRate: context.sampleRate, channels: 1, sequence: sequence,
        streamID: context.streamID, isFinal: true, bytes: Data([0, 0]), reply: context.descriptor
    )
    return try await submitSpeechAudio(Frame(
        timestamp: replyTimestamp(), target: context.descriptor.targetID, source: context.descriptor.hostID,
        payload: .audio(final)
    ), socketURL: context.socket)
}

private func sendStableVBSayFiles(
    in directory: URL, observed: inout [URL: Int], sent: inout Set<URL>, sequence: Int,
    context: PCMReplyContext
) async throws -> (frames: Int, deliveries: Int) {
    let files = try FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey]
    ).filter { $0.pathExtension == "raw" }.sorted { lhs, rhs in
        let left = try? lhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        let right = try? rhs.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate
        return (left ?? .distantPast) < (right ?? .distantPast)
    }
    var frames = 0
    var deliveries = 0
    for file in files where !sent.contains(file) {
        let size = try file.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, observed[file] == size else {
            observed[file] = size
            continue
        }
        let result = try await sendPCMFile(
            file, context: context, sequence: sequence + frames, marksFinal: false, renderedAudio: true
        )
        frames += result.frames
        deliveries += result.deliveries
        sent.insert(file)
    }
    return (frames, deliveries)
}

private func replyTimestamp() -> Int64 {
    Int64((Date().timeIntervalSince1970 * 1_000).rounded(.down))
}

private enum ReplyClientError: Error, CustomStringConvertible {
    case invalidSocket(String)
    case timeout
    case failed(String)
    case refused(String)

    var description: String {
        switch self {
        case .invalidSocket(let path): "invalid owner-only reply socket: \(path)"
        case .timeout: "local reply timed out"
        case .failed(let reason): reason
        case .refused(let reason): reason
        }
    }
}

enum ReplyClient {
    /// The owner-only socket boundary every local request shares: a socket file this user owns, 0600.
    static func requireOwnerSocket(_ socketURL: URL) throws {
        var info = stat()
        guard socketURL.isFileURL, lstat(socketURL.path, &info) == 0,
              info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFSOCK,
              info.st_mode & 0o077 == 0 else {
            throw ReplyClientError.invalidSocket(socketURL.path)
        }
    }

    /// One newline-terminated request, one answer, no retry. `haild rightyo --reply-to` dispatches through
    /// this; `submit` adds the reply-only pending retry window around the same transaction.
    static func transact(_ line: Data, socketURL: URL) async throws -> LocalReplyResponse {
        try requireOwnerSocket(socketURL)
        // The daemon's socket line cap (#200): a dispatch line may exceed the reply frame cap.
        guard line.count <= max(PayloadLimits.defaultMaxFrameBytes, LocalDispatchRequest.maxLineBytes) + 1 else {
            throw ReplyClientError.failed("frame too large")
        }
        return try await ReplyTransaction(socketURL: socketURL).perform(line)
    }

    static func submit(_ frame: Frame, socketURL: URL) async throws -> Int {
        try requireOwnerSocket(socketURL)
        var request = try FrameCoding.encode(frame)
        guard request.count <= PayloadLimits.defaultMaxFrameBytes else {
            throw ReplyClientError.failed("frame too large")
        }
        request.append(UInt8(ascii: "\n"))
        // Only this typed refusal promises that nothing was published. Keep the exact encoded frame
        // across retries; an ambiguous socket/send failure is never safe to retry automatically.
        let retryWindow = CorrelatedReplyRetryWindow()
        for attempt in 0..<CorrelatedReplyRetryWindow.maximumAttempts {
            try Task.checkCancellation()
            guard retryWindow.canStart(attempt: attempt) else {
                throw ReplyClientError.refused("reply request did not become ready within the retry budget")
            }
            let response = try await ReplyTransaction(socketURL: socketURL).perform(request)
            if response.code == .requestPending, response.delivered == 0 {
                guard try await retryWindow.waitForRetry(after: attempt) else {
                    throw ReplyClientError.refused("reply request did not become ready within the retry budget")
                }
                continue
            }
            if let error = response.error { throw ReplyClientError.refused(error) }
            guard response.code == nil, response.delivered == 1 else {
                throw ReplyClientError.refused("reply requires exactly one recipient")
            }
            return response.delivered
        }
        throw ReplyClientError.refused("reply retry budget exhausted")
    }
}

/// `haild rightyo --reply-to <connection>`: the running daemon dispatches each admitted prompt on behalf of the
/// named connection over the owner-only reply socket (#188 item 1, part B), so that phone owns the reply.
/// Refusals map to the codes `haild rightyo` already uses where the direct path has the same outcome
/// (`confirmationRequired` → 8, `bindingMismatch` → 7 as a rebound denial); every other dispatch or socket
/// refusal is reported with the daemon's reason and exits 1, as `haild reply` does.
struct RightyoSocketDispatcher: RightyoDispatching {
    /// Measured real `tmux send-keys` cost per chunk (~5.5 ms, #204 review), rounded up.
    static let sendKeysCost: Duration = .milliseconds(6)
    /// Half the daemon's 10-second socket submission deadline (`LocalReplyEndpoint`): the rest is margin for
    /// listing, binding checks and a slower host. Past the deadline the daemon abandons the typing unsent.
    static let typingBudget: Duration = .seconds(5)
    /// The largest prompt this client dispatches: what the daemon can type within `typingBudget` in
    /// `TmuxAdapter.defaultChunkSize`-character chunks (833 chunks, 333,200 bytes; a UTF-8 byte cap also bounds
    /// characters), never above the daemon's own dispatch cap. Realistic RightyO prompts are tens of KB.
    static let maxPromptBytes = min(
        LocalDispatchRequest.maxTextBytes, Int(typingBudget / sendKeysCost) * TmuxAdapter.defaultChunkSize
    )

    let connection: UUID
    let socketURL: URL

    func dispatch(text: String, target: String, binding: String) async throws -> RightyoDispatchReceipt {
        // Refused before connecting, with the reason: a longer prompt could not be typed within the daemon's
        // answer deadline (and past 1,200,000 bytes the daemon refuses it at decode).
        let cap = Self.maxPromptBytes
        guard text.utf8.count <= cap else {
            throw ReplyClientError.refused("prompt exceeds the \(cap)-byte --reply-to dispatch cap")
        }
        let request = LocalDispatchRequest(connection: connection, target: target, binding: binding, text: text)
        var line = try JSONEncoder().encode(request)
        line.append(UInt8(ascii: "\n"))
        return try Self.receipt(from: try await ReplyClient.transact(line, socketURL: socketURL), target: target)
    }

    /// `delivered: 1` means the prompt landed; `request` says whether the named connection owns the reply. A
    /// delivered answer without the `request` key is a reply answer from a daemon that does not dispatch:
    /// it is refused rather than read as ownership. Refusals carry the daemon's reason whatever their shape
    /// (the shared rate-limit, decode and audit answers have no `request` key either).
    static func receipt(from response: LocalReplyResponse, target: String) throws -> RightyoDispatchReceipt {
        if response.delivered == 1 {
            guard response.isDispatch else {
                throw ReplyClientError.refused("daemon answered as a reply, not a dispatch; it may predate --reply-to")
            }
            return RightyoDispatchReceipt(request: response.request, caveat: response.error)
        }
        let reason = response.error ?? "dispatch refused without a reason"
        switch Self.refusal(named: reason) {
        case .confirmationRequired: throw RightyoInputError.confirmationRequired
        case .bindingMismatch: throw HostError.denied(.rebound(target))
        default: throw ReplyClientError.refused(reason)
        }
    }

    /// The bracketed reason in `dispatch refused [<reason>]: ...`; nil for a socket-level or unknown refusal.
    static func refusal(named message: String) -> LocalDispatchRefusal? {
        guard let open = message.firstIndex(of: "["), let close = message[open...].firstIndex(of: "]") else {
            return nil
        }
        return LocalDispatchRefusal(rawValue: String(message[message.index(after: open)..<close]))
    }
}

private final class ReplyTransaction: @unchecked Sendable {
    private let queue = DispatchQueue(label: "hail.local-reply-client")
    private let connection: NWConnection
    private let lock = NSLock()
    private var continuation: CheckedContinuation<LocalReplyResponse, any Error>?
    private var sent = false

    init(socketURL: URL) {
        connection = NWConnection(to: .unix(path: socketURL.path), using: .tcp)
    }

    func perform(_ request: Data) async throws -> LocalReplyResponse {
        try await withCheckedThrowingContinuation { continuation in
            lock.withLock { self.continuation = continuation }
            connection.stateUpdateHandler = { [weak self] state in self?.changed(state, request: request) }
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + 15) { [weak self] in
                self?.finish(.failure(ReplyClientError.timeout))
            }
        }
    }

    private func changed(_ state: NWConnection.State, request: Data) {
        switch state {
        case .ready:
            let shouldSend = lock.withLock {
                guard !sent else { return false }
                sent = true
                return true
            }
            guard shouldSend else { return }
            connection.send(
                content: request, contentContext: .defaultMessage, isComplete: false,
                completion: .contentProcessed { [weak self] error in
                    if let error { self?.finish(.failure(error)) } else { self?.receive(Data()) }
                }
            )
        case .failed(let error):
            finish(.failure(ReplyClientError.failed("\(error)")))
        case .cancelled:
            finish(.failure(ReplyClientError.failed("connection cancelled")))
        default:
            break
        }
    }

    private func receive(_ buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1_024) { [weak self] data, _, done, error in
            guard let self else { return }
            if let error { finish(.failure(error)); return }
            var response = buffer
            if let data { response.append(data) }
            guard response.count <= 4 * 1_024 else {
                finish(.failure(ReplyClientError.failed("response too large")))
                return
            }
            if let newline = response.firstIndex(of: UInt8(ascii: "\n")) {
                do {
                    finish(.success(try JSONDecoder().decode(LocalReplyResponse.self, from: response[..<newline])))
                } catch {
                    finish(.failure(ReplyClientError.failed("malformed response")))
                }
            } else if done {
                finish(.failure(ReplyClientError.failed("response ended early")))
            } else {
                receive(response)
            }
        }
    }

    private func finish(_ result: Result<LocalReplyResponse, any Error>) {
        let pending = lock.withLock {
            let pending = continuation
            continuation = nil
            return pending
        }
        guard let pending else { return }
        connection.cancel()
        pending.resume(with: result)
    }
}
