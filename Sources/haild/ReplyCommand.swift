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
    var sampleRate = 24_000
    var socket = LocalReplyEndpoint.standardSocket()

    mutating func apply(_ flag: String, value: String) throws {
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
        default: throw ReplyCommandError.usage
        }
    }
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
    let streamID = (options.pcm16 != nil || options.say != nil) ? UUID() : nil
    let descriptor = ReplyDescriptor(
        id: UUID(), hostID: options.host, targetID: options.target, audioStreamID: streamID
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
        let result = try await streamVBSay(spoken, context: context)
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
    _ url: URL, context: PCMReplyContext, sequence startingSequence: Int, marksFinal: Bool
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
        deliveries += try await ReplyClient.submit(frame, socketURL: context.socket)
        sequence += 1
        current = next
    }
    return (sequence - startingSequence, deliveries)
}

// Generation, incremental publication, finalization, and child cleanup form one failure boundary.
// swiftlint:disable:next function_body_length
private func streamVBSay(
    _ text: String, context: PCMReplyContext
) async throws -> (frames: Int, deliveries: Int) {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
        "hailing-vbsay-\(UUID().uuidString)", isDirectory: true
    )
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: directory) }
    let process = try startVBSay(text, outputDirectory: directory)
    defer {
        if process.isRunning {
            process.terminate()
            process.waitUntilExit()
        }
    }

    var observed: [URL: Int] = [:]
    var sent: Set<URL> = []
    var sequence = 0, deliveries = 0
    do {
        while process.isRunning {
            let result = try await sendStableVBSayFiles(
                in: directory, observed: &observed, sent: &sent, sequence: sequence,
                context: context
            )
            sequence += result.frames
            deliveries += result.deliveries
            try await Task.sleep(for: .milliseconds(100))
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw ReplyCommandError.invalid("vbsay exited with status \(process.terminationStatus)")
        }
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
    return try await ReplyClient.submit(Frame(
        timestamp: replyTimestamp(), target: context.descriptor.targetID, source: context.descriptor.hostID,
        payload: .audio(final)
    ), socketURL: context.socket)
}

private func startVBSay(_ text: String, outputDirectory: URL) throws -> Process {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["vbsay", text]
    var environment = ProcessInfo.processInfo.environment
    environment["VBSAY_NOPLAY"] = "1"
    environment["VBSAY_OUT"] = outputDirectory.path
    environment["VBSAY_CHUNK"] = environment["VBSAY_CHUNK"] ?? "160"
    process.environment = environment
    process.standardOutput = FileHandle.nullDevice
    try process.run()
    return process
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
            file, context: context, sequence: sequence + frames, marksFinal: false
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

private enum ReplyClientError: Error {
    case invalidSocket(String)
    case timeout
    case failed(String)
    case refused(String)
}

private enum ReplyClient {
    static func submit(_ frame: Frame, socketURL: URL) async throws -> Int {
        var info = stat()
        guard socketURL.isFileURL, lstat(socketURL.path, &info) == 0,
              info.st_uid == getuid(), info.st_mode & S_IFMT == S_IFSOCK,
              info.st_mode & 0o077 == 0 else {
            throw ReplyClientError.invalidSocket(socketURL.path)
        }
        var request = try FrameCoding.encode(frame)
        guard request.count <= PayloadLimits.defaultMaxFrameBytes else {
            throw ReplyClientError.failed("frame too large")
        }
        request.append(UInt8(ascii: "\n"))
        while true {
            let response = try await ReplyTransaction(socketURL: socketURL).perform(request)
            if response.error == "rate limited" {
                try await Task.sleep(for: .seconds(1))
                continue
            }
            if let error = response.error { throw ReplyClientError.refused(error) }
            return response.delivered
        }
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
