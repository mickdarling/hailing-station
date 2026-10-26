import Darwin
import Foundation
import HailDaemonKit
import HailProtocol
import Synchronization

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
    var host = ""
    var text: String?
    var pcm16: URL?
    var say: String?
    /// #606: the reply's unspoken Markdown, from `--metadata` or `--metadata-file`; travels on its text frame.
    var metadata: String?
    var requestID: UUID?
    var rendererOutputRoot: URL?
    var sampleRate = 24_000
    var socket = LocalReplyEndpoint.standardSocket()

    /// Canonical at parse time, so an explicit empty or invalid `--host` is refused, never defaulted.
    private static func explicitHost(_ value: String) throws -> String {
        guard let host = HostIdentity.canonical(value) else { throw ReplyCommandError.usage }
        return host
    }

    /// A regular file of UTF-8 Markdown, its size checked before it is read: never a device, pipe or directory.
    private static func metadataFile(_ path: String) throws -> String {
        let url = URL(fileURLWithPath: path)
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard attributes?[.type] as? FileAttributeType == .typeRegular else {
            throw ReplyCommandError.invalid("metadata file must be a regular file")
        }
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        guard size <= PayloadLimits.maxMetadataBytes else { throw metadataTooLarge }
        guard let data = try? Data(contentsOf: url), let text = String(data: data, encoding: .utf8) else {
            throw ReplyCommandError.invalid("metadata file must be readable UTF-8")
        }
        return text
    }

    /// Metadata rides on the text frame, so it needs `--text` or `--say`: refused, never silently dropped.
    func requireSendableMetadata() throws {
        guard let metadata else { return }
        guard text != nil else { throw ReplyCommandError.invalid("metadata needs --text or --say") }
        guard !metadata.isEmpty else { throw ReplyCommandError.invalid("metadata is empty") }
        guard metadata.utf8.count <= PayloadLimits.maxMetadataBytes else { throw metadataTooLarge }
    }

    /// The flags beside the reply's own content: the renderer root, and `--metadata` or `--metadata-file` (at most one
    /// of them). False for any other flag.
    private mutating func applyAncillary(_ flag: String, value: String) throws -> Bool {
        switch flag {
        case "--renderer-output-root": rendererOutputRoot = URL(fileURLWithPath: value, isDirectory: true)
        case "--metadata", "--metadata-file":
            guard metadata == nil else { throw ReplyCommandError.usage }
            metadata = flag == "--metadata" ? value : try Self.metadataFile(value)
        default: return false
        }
        return true
    }

    mutating func apply(_ flag: String, value: String) throws {
        if try applyAncillary(flag, value: value) { return }
        switch flag {
        case "--host": host = try Self.explicitHost(value)
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

private let metadataTooLarge = ReplyCommandError.invalid("metadata exceeds \(PayloadLimits.maxMetadataBytes) bytes")

private func parseReplyRequest(_ value: String) throws -> UUID {
    guard let id = UUID(uuidString: value) else { throw ReplyCommandError.invalid("request must be a UUID") }
    return id
}

private struct PCMReplyContext {
    var sampleRate: Int
    var streamID: UUID
    var descriptor: ReplyDescriptor
    var socket: URL
    /// The job's pacing (#430): a long reply plays in full, under the endpoint's per-minute frame limit.
    var pacing: ReplyStreamPacing
    /// A foreground reply (`HAILD_REPLY_FOREGROUND=1`, set by the owned publisher, which supervises the CLI's own
    /// process group) keeps main's per-job frame budget, with the terminal frame reserved: unpaced, a long one is
    /// refused whole or ends with an accepted final marker, never cut off mid-stream. Nil for a detached reply.
    var frameLimit: Int?
    /// A spoken reply's delivery timing (#737), logged once when it ends.
    var timing: ReplyTimingRecorder?
}

func reply(_ arguments: ArraySlice<String>) async throws {
    let options = try replyOptions(arguments)
    let rendererRoot = options.rendererOutputRoot ?? FileManager.default.temporaryDirectory
    if options.say != nil { try OwnedReplyRenderer.validateOutputRoot(rendererRoot) }
    // Every spoken reply is paced and detached (#430). A `--request` one too (#467): its request stays current
    // while the stream flows, and `RequestKeepAlive` keeps the stream from going quiet past that.
    let foreground = ProcessInfo.processInfo.environment["HAILD_REPLY_FOREGROUND"] == "1"
    let audio = (options.pcm16 != nil || options.say != nil) && !foreground
    let pacingOff = ProcessInfo.processInfo.environment["HAILD_REPLY_PACING"] == "off"
    if let file = options.pcm16 {
        try requireWithinAudioBound(file, sampleRate: options.sampleRate, paced: audio && !pacingOff,
                                    text: options.text != nil)
    }
    if audio, pacingOff, !ReplyBackground.isDetachedJob {
        note("HAILD_REPLY_PACING=off: sending without pacing; the endpoint's per-minute limit still applies")
    }
    let pacing = ReplyStreamPacing(paced: audio && !pacingOff)
    guard audio else { return try await streamReply(options, rendererRoot: rendererRoot, pacing: pacing) }
    guard ReplyBackground.isDetachedJob else { try ReplyBackground.detach() }
    try await ReplyBackground.bounded { try await streamReply(options, rendererRoot: rendererRoot, pacing: pacing) }
}

/// Checked before any text is sent. A paced static file must also fit its frames into the paced sending time: at a
/// high sample rate each 48 KiB segment is short, so 30 minutes of audio can need more frames than 100 a minute
/// sends within the detached job's bound.
private func requireWithinAudioBound(_ file: URL, sampleRate: Int, paced: Bool, text: Bool) throws {
    let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? 0
    guard ReplyStreamPacer.seconds(pcm16Bytes: size, sampleRate: sampleRate) <= ReplyStreamPacer.maxAudioSeconds
    else { throw audioBoundRefusal }
    let frames = (size + pcmSegmentBytes - 1) / pcmSegmentBytes + (text ? 1 : 0)
    let sendable = Int(ReplyStreamPacer.maxAudioSeconds / 60) * ReplyStreamPacer.framesPerMinute
    guard !paced || frames <= sendable else {
        throw ReplyCommandError.invalid("PCM16 reply needs \(frames) frames; at most \(sendable) can be paced")
    }
}

private let pcmSegmentBytes = 48 * 1_024

/// The reply's text frame, carrying any metadata (#606); nil when the reply has no text.
private func textFrame(_ options: ReplyOptions, descriptor: ReplyDescriptor) -> Frame? {
    options.text.map { text in
        Frame(
            timestamp: replyTimestamp(), target: options.target, source: options.host,
            payload: .text(TextPayload(text: text, reply: descriptor, metadata: options.metadata))
        )
    }
}

/// #606: JSON escaping can grow text and metadata within their byte caps past the whole-frame cap (a control
/// character is six bytes on the wire). Checked on a stand-in frame of the same shape (UUIDs and a millisecond
/// timestamp encode at fixed widths) before anything is sent, and before a spoken reply detaches.
private func requireTextFrameFits(_ options: ReplyOptions) throws {
    let descriptor = ReplyDescriptor(
        id: UUID(), hostID: options.host, targetID: options.target,
        audioStreamID: options.pcm16 != nil || options.say != nil ? UUID() : nil, requestID: options.requestID
    )
    guard let frame = textFrame(options, descriptor: descriptor) else { return }
    let size = try FrameCoding.encode(frame).count
    guard size <= PayloadLimits.defaultMaxFrameBytes else {
        throw ReplyCommandError.invalid(
            "text and metadata encode to \(size) bytes; a frame holds at most \(PayloadLimits.defaultMaxFrameBytes)"
        )
    }
}

private func streamReply(_ options: ReplyOptions, rendererRoot: URL, pacing: ReplyStreamPacing) async throws {
    let streamID = (options.pcm16 != nil || options.say != nil) ? UUID() : nil
    let descriptor = ReplyDescriptor(
        id: UUID(), hostID: options.host, targetID: options.target, audioStreamID: streamID,
        requestID: options.requestID
    )
    var frames = 0, deliveries = 0
    RequestKeepAlive.begin(requestBound: options.requestID != nil)
    if let frame = textFrame(options, descriptor: descriptor) {
        try await admit(audioBytes: 0, sampleRate: options.sampleRate, pacing: pacing)
        deliveries += try await ReplyBackground.submit(frame, socketURL: options.socket)
        frames += 1
    }
    guard let streamID else { return printSubmitted(frames: frames, deliveries: deliveries) }
    try await ReplyBackground.awaitAudioTurn(socket: options.socket, target: options.target)
    let context = PCMReplyContext(
        sampleRate: options.sampleRate, streamID: streamID, descriptor: descriptor,
        socket: options.socket, pacing: pacing,
        frameLimit: ReplyBackground.isDetachedJob ? nil
            : LocalReplyEndpoint.maxFramesPerMinute - (options.text == nil ? 0 : 1)
    )
    if let file = options.pcm16 {
        let result = try await sendPCM(file, context: context)
        frames += result.frames
        deliveries += result.deliveries
    }
    if let spoken = options.say {
        let result = try await streamVBSay(spoken, outputRoot: rendererRoot, context: context)
        frames += result.frames
        deliveries += result.deliveries
    }
    printSubmitted(frames: frames, deliveries: deliveries)
}

private func printSubmitted(frames: Int, deliveries: Int) {
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
    if options.host.isEmpty { options.host = try HostIdentity.resolve() }
    guard !options.host.isEmpty, options.text != nil || options.pcm16 != nil,
          options.pcm16 == nil || options.say == nil else {
        throw ReplyCommandError.usage
    }
    if let text = options.text, text.utf8.count > PayloadLimits.maxTextBytes {
        throw ReplyCommandError.invalid("text exceeds \(PayloadLimits.maxTextBytes) bytes")
    }
    try options.requireSendableMetadata()
    try requireTextFrameFits(options)
    if options.say != nil, options.sampleRate != 24_000 {
        throw ReplyCommandError.invalid("vbsay output is fixed at 24000 Hz")
    }
    if options.rendererOutputRoot != nil, options.say == nil { throw ReplyCommandError.usage }
    if let say = options.say { options.say = labelled(say, from: options.target) }
    return options
}

/// The owner's voice routes (#636) name the session that answered, in speech only; the text frame is unchanged.
/// Unreadable routes leave the reply unlabelled, and say so: the reply itself still goes.
private func labelled(_ say: String, from target: String) -> String {
    do {
        return try VoiceRoutes.load(VoiceRoutes.standardFile())?.spoken(say, from: target) ?? say
    } catch {
        note("voice routes unreadable (\(error)); reply not labelled")
        return say
    }
}

private func sendPCM(
    _ url: URL, context: PCMReplyContext
) async throws -> (frames: Int, deliveries: Int) {
    try await sendPCMFile(
        url, context: context, sequence: 0, marksFinal: true
    )
}

/// A static file's shape, its audio bound and, for a foreground reply, its frame budget, before any frame of it.
private func requireSendable(_ url: URL, context: PCMReplyContext, from start: Int, marksFinal: Bool) throws {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
    let segments = (size + pcmSegmentBytes - 1) / pcmSegmentBytes
    guard size > 0, size.isMultiple(of: 2), segments > 0 else {
        throw ReplyCommandError.invalid("PCM16 reply is empty or has a partial sample")
    }
    guard ReplyStreamPacer.seconds(pcm16Bytes: size, sampleRate: context.sampleRate)
            <= ReplyStreamPacer.maxAudioSeconds else { throw audioBoundRefusal }
    if let limit = context.frameLimit, start + segments > limit - (marksFinal ? 0 : 1) { throw frameBudgetRefusal }
}

private func sendPCMFile(
    _ url: URL, context: PCMReplyContext, sequence startingSequence: Int, marksFinal: Bool, renderedAudio: Bool = false
) async throws -> (frames: Int, deliveries: Int) {
    try requireSendable(url, context: context, from: startingSequence, marksFinal: marksFinal)
    let segmentBytes = pcmSegmentBytes
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    var current = try handle.read(upToCount: segmentBytes) ?? Data()
    var sequence = startingSequence
    var deliveries = 0
    do {
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
            try await admit(audioBytes: current.count, sampleRate: context.sampleRate, pacing: context.pacing)
            if renderedAudio {
                deliveries += try await submitSpeechAudio(frame, socketURL: context.socket)
            } else {
                deliveries += try await ReplyBackground.submit(frame, socketURL: context.socket)
                ReplyBackground.ready()
            }
            sequence += 1
            current = next
        }
    } catch {
        // A static reply that stops partway still ends its stream, so the phone's queue moves on (#467).
        if marksFinal, sequence > startingSequence {
            _ = try? await sendFinalPCM(sequence: sequence, context: context, paced: false)
        }
        throw error
    }
    return (sequence - startingSequence, deliveries)
}

// Generation, incremental publication, finalization, and child cleanup form one failure boundary.
private func streamVBSay(
    _ text: String, outputRoot: URL, context: PCMReplyContext
) async throws -> (frames: Int, deliveries: Int) {
    var context = context
    let timing = ReplyTimingRecorder()
    context.timing = timing
    // "played" once the renderer's audio is all sent, even if its cleanup then fails the command.
    var outcome = "failed"
    defer { timing.log(outcome: outcome) }
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
        outcome = "played"
        try await renderer.waitForCleanup()
        return result
    } catch {
        if outcome == "failed", ReplyBackground.isSuperseded {
            outcome = "superseded"
        } else if outcome == "failed",
                  error is CancellationError || Task.isCancelled || error as? OwnedReplyRendererError == .cancelled {
            outcome = "cancelled"
        }
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
    do {
        let delivered = try await ReplyBackground.submit(frame, socketURL: socketURL)
        ReplyBackground.ready() // A detached job's first accepted audio lets `haild reply` return (#430).
        return delivered
    } catch {
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
        // Relay stdout PCM as it arrives (#268): no files, no polling.
        var pending = Data()
        for try await bytes in renderer.audio {
            pending.append(bytes)
            while pending.count >= StreamedReplyFrames.bytes(sequence: sequence) {
                let size = StreamedReplyFrames.bytes(sequence: sequence)
                deliveries += try await sendStreamedPCM(pending.prefix(size), sequence: sequence, context: context)
                pending.removeFirst(size)
                sequence += 1
            }
        }
        try await renderer.requireSuccessfulExit()
        guard pending.count.isMultiple(of: 2) else { throw ReplyCommandError.invalid("vbsay wrote a partial sample") }
        if !pending.isEmpty {
            deliveries += try await sendStreamedPCM(pending, sequence: sequence, context: context)
            sequence += 1
        }
        if sequence == 0 {
            // A vbsay without VBSAY_STDOUT writes only files; two passes establish their stability.
            for _ in 0..<2 {
                let result = try await sendStableVBSayFiles(
                    in: directory, observed: &observed, sent: &sent, sequence: sequence,
                    context: context
                )
                sequence += result.frames
                deliveries += result.deliveries
            }
        }
        guard sequence > 0 else { throw ReplyCommandError.invalid("vbsay produced no PCM audio") }
    } catch {
        if sequence > 0, sequence < context.frameLimit ?? .max {
            _ = try? await sendFinalPCM(sequence: sequence, context: context, paced: false)
        }
        throw error
    }
    deliveries += try await sendFinalPCM(sequence: sequence, context: context)
    return (sequence + 1, deliveries)
}

/// Streamed frame sizes: a short first frame so the phone starts quickly, then larger frames so a long reply needs
/// fewer of the endpoint's per-minute frames. Each frame is generated at ~2.5x realtime, well before the one ahead
/// of it finishes playing; `ReplyStreamPacing` holds the rest back to stay a bounded lead ahead of playback.
enum StreamedReplyFrames {
    static func bytes(sequence: Int) -> Int {
        switch sequence {
        case 0: 24_000 // 0.5 s at 24 kHz s16 mono
        case 1: 36_000 // 0.75 s
        default: 60_000 // 1.25 s, under PayloadLimits.maxAudioBytes
        }
    }
}

private let audioBoundRefusal = ReplyCommandError.invalid(
    "reply audio exceeds the \(Int(ReplyStreamPacer.maxAudioSeconds / 60))-minute bound"
)

/// Waits for this frame's turn under the job's pacing; the audio bound is a command refusal, not a renderer failure.
private func admit(audioBytes: Int, sampleRate: Int, pacing: ReplyStreamPacing) async throws {
    try ReplyBackground.requireCaller()
    guard !ReplyBackground.isSuperseded else { throw supersededRefusal }
    do {
        try await pacing.admit(audio: ReplyStreamPacer.seconds(pcm16Bytes: audioBytes, sampleRate: sampleRate),
                               latest: RequestKeepAlive.latest(final: false), lead: try ReplyBackground.audioLead())
    } catch ReplyStreamPacerError.audioBoundExceeded {
        throw audioBoundRefusal
    }
}

private let supersededRefusal = ReplyCommandError.invalid("a newer reply to this target took over")
private let frameBudgetRefusal = ReplyCommandError.invalid("PCM16 reply exceeds the endpoint frame budget")

private func sendStreamedPCM(_ bytes: Data, sequence: Int, context: PCMReplyContext) async throws -> Int {
    // A foreground reply keeps one frame reserved for the terminal marker.
    if let limit = context.frameLimit, sequence + 1 >= limit { throw frameBudgetRefusal }
    try await admit(audioBytes: bytes.count, sampleRate: context.sampleRate, pacing: context.pacing)
    let payload = AudioPayload(
        codec: .pcm16, sampleRate: context.sampleRate, channels: 1, sequence: sequence,
        streamID: context.streamID, isFinal: false, bytes: Data(bytes), reply: context.descriptor
    )
    let (sentAt, resendsBefore) = (ContinuousClock.now, ReplyResends.total)
    let delivered = try await submitSpeechAudio(Frame(
        timestamp: replyTimestamp(), target: context.descriptor.targetID, source: context.descriptor.hostID,
        payload: .audio(payload)
    ), socketURL: context.socket)
    let audio = ReplyStreamPacer.seconds(pcm16Bytes: bytes.count, sampleRate: context.sampleRate)
    let resends = ReplyResends.total - resendsBefore
    context.timing?.sent(audio: .seconds(audio), at: sentAt, acknowledgedAfter: .now - sentAt, resends: resends)
    return delivered
}

/// `paced: false` when a stream is being given up: its terminal marker goes at once, while its request is current.
private func sendFinalPCM(sequence: Int, context: PCMReplyContext, paced: Bool = true) async throws -> Int {
    if paced { try await admit(audioBytes: 0, sampleRate: context.sampleRate, pacing: context.pacing) }
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

enum ReplyClientError: Error, CustomStringConvertible {
    case invalidSocket(String)
    case timeout
    case failed(String)
    case refused(String)
    /// The request was written but no answer came back: the outcome on the daemon side is unknown.
    case unanswered(String)

    var description: String {
        switch self {
        case .invalidSocket(let path): "invalid owner-only reply socket: \(path)"
        case .timeout: "local reply timed out"
        case .failed(let reason): reason
        case .refused(let reason): reason
        case .unanswered(let reason):
            "no answer after the dispatch was sent (\(reason)): the prompt may have been submitted, or typed and "
                + "left unsubmitted in the target's input line; check the pane before retrying"
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
        do { return try await ReplyTransaction.perform(line, socketURL: socketURL) } catch let failure {
            // Once written, a lost answer is not a refusal: the daemon may have delivered (#204).
            guard failure.didSend else { throw failure.error }
            throw ReplyClientError.unanswered("\(failure.error)")
        }
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
            let response: LocalReplyResponse
            do { response = try await ReplyTransaction.perform(request, socketURL: socketURL) } catch let failure {
                throw failure.error
            }
            if response.code == .requestPending, response.delivered == 0 {
                guard try await retryWindow.waitForRetry(after: attempt) else {
                    throw ReplyClientError.refused("reply request did not become ready within the retry budget")
                }
                ReplyResends.note()
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
    /// Measured real tmux cost per chunk (~5.5 ms for `send-keys`, #204 review; a `set-buffer` fill is the same
    /// single invocation, #304), rounded up.
    static let sendKeysCost: Duration = .milliseconds(6)
    /// The daemon's socket submission deadline (`LocalReplyEndpoint`'s default). Before the commit point the
    /// daemon abandons a delivery that outlives it, and a text already pasted then taints the pane.
    static let submissionDeadline: Duration = .seconds(10)
    /// What may go to filling the paste buffer: the deadline less the longest wait for text already pending at the
    /// cursor to leave (`clearLimit`, 3 s), the longest wait for the pasted text to appear (`settleLimit`, 4 s), both
    /// from `TmuxSubmitTiming.standard`, and one second for listing, binding checks and a slower host. After the
    /// commit point the Enter, its confirmation and at most one retry can take up to about three confirm limits
    /// (about 6 s); that runs to completion whether or not the client is still waiting.
    static let typingBudget: Duration = submissionDeadline - TmuxSubmitTiming.standard.clearLimit
        - TmuxSubmitTiming.standard.settleLimit - .seconds(1)
    /// The largest prompt this client dispatches: what the daemon can type within `typingBudget` in
    /// `TmuxAdapter.defaultChunkSize`-character chunks (333 chunks, 133,200 bytes; a UTF-8 byte cap also bounds
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

/// A transaction's failure, and whether its request had been handed to the socket when it failed.
private struct ReplyTransactionFailure: Error {
    let error: any Error
    let didSend: Bool
}

/// The connection failed before anything was written: nothing reached the daemon, so it is safe to try again.
private struct ReplyConnectFailure: Error, CustomStringConvertible {
    let error: any Error
    var description: String { "\(error)" }
}

/// A failed socket call, worded as `NWError.posix` was, so refusal and `unanswered` texts are unchanged (#144).
private struct ReplySocketError: Error, CustomStringConvertible {
    let code: Int32
    var description: String { "POSIXErrorCode(rawValue: \(code)): \(String(cString: strerror(code)))" }
}

/// One request and its one-line answer over the daemon's owner-only Unix socket. A plain `AF_UNIX` stream socket,
/// non-blocking with `poll` deadlines, on one serial queue (#144): Network.framework evaluated a network path even
/// for this local socket and could fail a request the daemon had already received with "Network is down".
private final class ReplyTransaction: Sendable {
    /// #144: a connection that fails before anything is written (the daemon not yet listening, a transient
    /// "Network is down") is tried again on a fresh connection after these waits. Nothing reached the daemon, so a
    /// retry cannot deliver twice. Once the request is written nothing is retried here (#204).
    static let connectBackoff: [Duration] = [.milliseconds(100), .milliseconds(300), .milliseconds(900), .seconds(2)]
    static let timeout: Duration = .seconds(15)
    static let responseLimit = 4 * 1_024

    static func perform(
        _ request: Data, socketURL: URL
    ) async throws(ReplyTransactionFailure) -> LocalReplyResponse {
        for wait in connectBackoff + [nil] {
            let transaction = ReplyTransaction(socketURL: socketURL)
            do { return try await transaction.perform(request) } catch let refused as ReplyConnectFailure {
                guard let wait else {
                    throw ReplyTransactionFailure(error: ReplyClientError.failed(refused.description), didSend: false)
                }
                do { try await Task.sleep(for: wait) } catch {
                    throw ReplyTransactionFailure(error: error, didSend: false)
                }
            } catch {
                throw ReplyTransactionFailure(error: error, didSend: transaction.didSend)
            }
        }
        throw ReplyTransactionFailure(error: ReplyClientError.failed("connection failed"), didSend: false)
    }

    private static let queue = DispatchQueue(label: "hail.local-reply-client")
    private let path: String
    private let state = Mutex((sent: false, cancelled: false))
    /// Whether the request was handed to the socket; a failure after that has an unknown outcome.
    var didSend: Bool { state.withLock { $0.sent } }

    init(socketURL: URL) {
        path = socketURL.path
    }

    func perform(_ request: Data) async throws -> LocalReplyResponse {
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                Self.queue.async { continuation.resume(with: Result { try self.exchange(request) }) }
            }
        } onCancel: {
            state.withLock { $0.cancelled = true }
        }
    }

    private func exchange(_ request: Data) throws -> LocalReplyResponse {
        let deadline = ContinuousClock.now.advanced(by: Self.timeout)
        let socket = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socket >= 0 else { throw ReplyConnectFailure(error: ReplySocketError(code: errno)) }
        defer { close(socket) }
        var on: Int32 = 1
        _ = setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        _ = fcntl(socket, F_SETFD, FD_CLOEXEC)
        guard fcntl(socket, F_SETFL, fcntl(socket, F_GETFL) | O_NONBLOCK) >= 0 else {
            throw ReplyConnectFailure(error: ReplySocketError(code: errno))
        }
        try open(socket, deadline: deadline)
        state.withLock { $0.sent = true }
        try send(request, on: socket, deadline: deadline)
        return try receive(on: socket, deadline: deadline)
    }

    /// Connects, or throws a pre-send failure the caller may retry.
    private func open(_ socket: Int32, deadline: ContinuousClock.Instant) throws {
        var address = sockaddr_un()
        let bytes = Array(path.utf8)
        guard bytes.count < MemoryLayout.size(ofValue: address.sun_path) else {
            throw ReplyClientError.failed("\(ReplySocketError(code: ENAMETOOLONG))")
        }
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(socket, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard result != 0 else { return }
        guard errno == EINPROGRESS || errno == EINTR else {
            throw ReplyConnectFailure(error: ReplySocketError(code: errno))
        }
        try wait(socket, for: Int16(POLLOUT), deadline: deadline)
        var error: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(socket, SOL_SOCKET, SO_ERROR, &error, &length) == 0, error == 0 else {
            throw ReplyConnectFailure(error: ReplySocketError(code: error == 0 ? errno : error))
        }
    }

    private func send(_ request: Data, on socket: Int32, deadline: ContinuousClock.Instant) throws {
        var offset = 0
        while offset < request.count {
            let written = request.withUnsafeBytes { bytes in
                Darwin.send(socket, bytes.baseAddress?.advanced(by: offset), request.count - offset, 0)
            }
            if written > 0 { offset += written; continue }
            guard written < 0, errno == EAGAIN || errno == EINTR else { throw ReplySocketError(code: errno) }
            try wait(socket, for: Int16(POLLOUT), deadline: deadline)
        }
    }

    /// Reads the one-line answer: at most `responseLimit` bytes, ending in a newline.
    private func receive(on socket: Int32, deadline: ContinuousClock.Instant) throws -> LocalReplyResponse {
        var response = Data()
        var buffer = [UInt8](repeating: 0, count: 1_024)
        while true {
            if let newline = response.firstIndex(of: UInt8(ascii: "\n")) {
                do { return try JSONDecoder().decode(LocalReplyResponse.self, from: response[..<newline]) } catch {
                    throw ReplyClientError.failed("malformed response")
                }
            }
            let count = buffer.withUnsafeMutableBytes { Darwin.recv(socket, $0.baseAddress, $0.count, 0) }
            if count > 0 {
                response.append(contentsOf: buffer[0..<count])
                guard response.count <= Self.responseLimit else { throw ReplyClientError.failed("response too large") }
                continue
            }
            if count == 0 { throw ReplyClientError.failed("response ended early") }
            guard errno == EAGAIN || errno == EINTR else { throw ReplySocketError(code: errno) }
            try wait(socket, for: Int16(POLLIN), deadline: deadline)
        }
    }

    /// Waits for `events` in short slices, so a cancelled task stops within 100 ms and the deadline is exact.
    private func wait(_ socket: Int32, for events: Int16, deadline: ContinuousClock.Instant) throws {
        while true {
            if state.withLock({ $0.cancelled }) { throw CancellationError() }
            let remaining = ContinuousClock.now.duration(to: deadline)
            guard remaining > .zero else { throw ReplyClientError.timeout }
            let slice = Int32(min(100, max(1, remaining / .milliseconds(1))))
            var descriptor = pollfd(fd: socket, events: events, revents: 0)
            let ready = poll(&descriptor, 1, slice)
            if ready > 0 { return }
            if ready < 0, errno != EINTR { throw ReplySocketError(code: errno) }
        }
    }
}

private struct ReplyAudioTurn {
    let id: UUID
    let stop: URL
    let waiters: Int32
}

// Sharing the phone and the endpoint with other detached replies.
extension ReplyBackground {
    /// This job's audio-turn lock and the stop file that supersedes it (#467), once it holds the turn.
    private static let turn = Mutex<ReplyAudioTurn?>(nil)

    /// One detached reply's audio at a time per reply socket (#430). The phone plays replies one after another, so a
    /// second reply sent alongside the first would sit almost whole in the phone's queue, and two paced jobs would
    /// share the endpoint's per-minute frames. A queued job tells its caller and waits; its text has already gone.
    /// The lock is a file beside the owner-only socket, held open for the job's life: the kernel drops it at exit.
    ///
    /// A request-bound reply (#467) answers what the user just said, so it supersedes an older reply still playing
    /// to the same target: it leaves a stop file named for that job, which ends at its next frame with its terminal
    /// marker. It waits only while its own request stays current; past that its audio is skipped before any starts.
    static func awaitAudioTurn(socket: URL, target: String) async throws {
        guard isDetachedJob else { return }
        let directory = socket.deletingLastPathComponent()
        let lock = try openAudioLock("reply-audio.lock", directory: directory)
        let waiters: Int32
        do { waiters = try openAudioLock("reply-audio.waiters", directory: directory) } catch {
            close(lock)
            throw error
        }
        var queued = false, ownsTurn = false, superseding: URL?
        defer { if !ownsTurn { close(lock); close(waiters) } }
        defer { _ = flock(waiters, LOCK_UN) } // queued signal ends on acquisition, failure or cancellation
        defer { restartBound() } // a queued job gets the whole bound for its own stream (Codex P1)
        defer { if let superseding { try? FileManager.default.removeItem(at: superseding) } } // on every exit
        while flock(lock, LOCK_EX | LOCK_NB) != 0 {
            guard errno == EWOULDBLOCK || errno == EINTR else {
                throw ReplyCommandError.invalid("cannot take the reply audio lock")
            }
            if superseding == nil { superseding = requestSupersession(lock, target: target, directory: directory) }
            if !queued {
                try signalAudioWaiter(waiters)
                queued = true
                suspendBound()
                note("reply audio queued behind another reply")
                ready()
            }
            if let latest = RequestKeepAlive.latest(final: false), ContinuousClock.now >= latest {
                throw ReplyCommandError.invalid("another reply is still playing; this reply's audio was skipped")
            }
            try await Task.sleep(for: .milliseconds(250))
        }
        ownsTurn = true
        let id = UUID()
        let record = Data("\(id.uuidString) \(target)\n".utf8)
        _ = ftruncate(lock, 0)
        _ = record.withUnsafeBytes { pwrite(lock, $0.baseAddress, $0.count, 0) }
        let stop = directory.appendingPathComponent("reply-audio.stop-\(id.uuidString)")
        turn.withLock { $0 = ReplyAudioTurn(id: id, stop: stop, waiters: waiters) }
    }

    private static func openAudioLock(_ name: String, directory: URL) throws -> Int32 {
        let descriptor = open(directory.appendingPathComponent(name).path,
                              O_RDWR | O_CREAT | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard descriptor >= 0 else { throw ReplyCommandError.invalid("cannot open the reply audio lock") }
        return descriptor
    }

    private static func signalAudioWaiter(_ waiters: Int32) throws {
        guard flock(waiters, LOCK_SH) == 0 else {
            throw ReplyCommandError.invalid("cannot signal the reply audio waiter")
        }
    }

    private static func requestSupersession(_ lock: Int32, target: String, directory: URL) -> URL? {
        guard RequestKeepAlive.isRequestBound, let holder = turnHolder(lock), holder.target == target else {
            return nil
        }
        let stop = directory.appendingPathComponent("reply-audio.stop-\(holder.id.uuidString)")
        let owned: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
        return FileManager.default.createFile(atPath: stop.path, contents: nil, attributes: owned) ? stop : nil
    }

    /// Probe before each frame: shared waiter locks are released by the kernel even after SIGKILL.
    /// The holder keeps this separate descriptor open, without a shared lock, for its entire turn.
    static func audioLead() throws -> Double {
        guard let waiters = turn.withLock({ $0?.waiters }) else { return ReplyStreamPacer.leadSeconds }
        if flock(waiters, LOCK_EX | LOCK_NB) == 0 {
            _ = flock(waiters, LOCK_UN)
            return ReplyStreamPacer.leadSeconds
        }
        guard errno == EWOULDBLOCK else {
            throw ReplyCommandError.invalid("cannot inspect the reply audio waiters")
        }
        return ReplyStreamPacer.queuedLeadSeconds
    }

    /// Whether a newer request-bound reply to the same target has asked this job to end (#467).
    static var isSuperseded: Bool {
        guard let stop = turn.withLock({ $0?.stop }) else { return false }
        return FileManager.default.fileExists(atPath: stop.path)
    }

    private static func turnHolder(_ lock: Int32) -> (id: UUID, target: String)? {
        var buffer = [UInt8](repeating: 0, count: 512)
        let count = buffer.withUnsafeMutableBytes { pread(lock, $0.baseAddress, $0.count, 0) }
        guard count > 0, let line = String(bytes: buffer[0..<count], encoding: .utf8)?
            .split(separator: "\n").first else { return nil }
        let parts = line.split(separator: " ", maxSplits: 1)
        guard parts.count == 2, let id = UUID(uuidString: String(parts[0])) else { return nil }
        return (id, String(parts[1]))
    }

    /// In a detached job, a frame the endpoint refused for its shared per-minute limit is sent again once there is
    /// room: that refusal comes before anything is published. A target-only job extends its bound for the wait; a
    /// request-bound one (#467) stops resending in time to keep its request current, leaving room for the terminal
    /// marker. Every other outcome, and every foreground reply, is unchanged.
    static func submit(_ frame: Frame, socketURL: URL) async throws -> Int {
        let final = if case .audio(let audio) = frame.payload { audio.isFinal } else { false }
        while true {
            do {
                let delivered = try await ReplyClient.submit(frame, socketURL: socketURL)
                RequestKeepAlive.accepted()
                return delivered
            } catch let error {
                guard isDetachedJob, case ReplyClientError.refused("rate limited") = error else { throw error }
                // A superseded job stops resending its audio at once; only its terminal marker is still sent.
                if !final, isSuperseded { throw supersededRefusal }
                if let latest = RequestKeepAlive.latest(final: final) {
                    guard ContinuousClock.now.advanced(by: .seconds(2)) < latest else { throw error }
                } else {
                    extendBound(by: .seconds(2)) // waiting on others' traffic is not the stream's own time
                }
                try await Task.sleep(for: .seconds(2))
                ReplyResends.note()
            }
        }
    }
}

/// Resend waits this job made after a refusal that promises nothing was published (#737). Each audio frame takes the
/// difference across its own send, so the timing line counts only the waits inside the frames it times.
enum ReplyResends {
    private static let count = Mutex(0)

    static func note() { count.withLock { $0 += 1 } }
    static var total: Int { count.withLock { $0 } }
}

/// #467: a request-bound reply keeps its host-minted request current only while its accepted frames come within the
/// Listener's 60 s idle gap (`HostReplyRequest.streamIdleGap`). Its pacing waits and rate-limit resends stop
/// `dataBudget` after the last accepted frame, which leaves the rest of the gap for the terminal marker.
enum RequestKeepAlive {
    static let dataBudget: Duration = .seconds(40)
    static let finalBudget: Duration = .seconds(55)
    private static let state = Mutex((bound: false, last: ContinuousClock.now))

    static func begin(requestBound: Bool) { state.withLock { $0 = (requestBound, .now) } }
    static func accepted() { state.withLock { $0.last = .now } }
    static var isRequestBound: Bool { state.withLock { $0.bound } }

    /// The latest a request-bound frame may go; nil for a target-only reply, which has no request to keep.
    static func latest(final: Bool) -> ContinuousClock.Instant? {
        state.withLock { $0.bound ? $0.last.advanced(by: final ? finalBudget : dataBudget) : nil }
    }
}
