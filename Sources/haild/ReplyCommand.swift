import Foundation
import HailDaemonKit
import HailProtocol

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
    var sampleRate = 24_000
    var socket = LocalReplyEndpoint.standardSocket()

    mutating func apply(_ flag: String, value: String) throws {
        switch flag {
        case "--host": host = value
        case "--text": text = value
        case "--pcm16": pcm16 = URL(fileURLWithPath: value)
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

func reply(_ arguments: ArraySlice<String>) async throws {
    let options = try replyOptions(arguments)
    let streamID = options.pcm16.map { _ in UUID() }
    let descriptor = ReplyDescriptor(
        id: UUID(), hostID: options.host, targetID: options.target, audioStreamID: streamID
    )
    var frames = 0
    var deliveries = 0
    if let text = options.text {
        let frame = Frame(
            timestamp: replyTimestamp(), target: options.target, source: options.host,
            payload: .text(TextPayload(text: text, reply: descriptor))
        )
        deliveries += try await LocalReplyClient.submit(frame, socketURL: options.socket)
        frames += 1
    }
    if let file = options.pcm16, let streamID {
        let result = try await sendPCM(
            file, sampleRate: options.sampleRate, streamID: streamID,
            descriptor: descriptor, socket: options.socket
        )
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
    guard !options.host.isEmpty, options.text != nil || options.pcm16 != nil else {
        throw ReplyCommandError.usage
    }
    if let text = options.text, text.utf8.count > PayloadLimits.maxTextBytes {
        throw ReplyCommandError.invalid("text exceeds \(PayloadLimits.maxTextBytes) bytes")
    }
    return options
}

private func sendPCM(
    _ url: URL, sampleRate: Int, streamID: UUID, descriptor: ReplyDescriptor, socket: URL
) async throws -> (frames: Int, deliveries: Int) {
    let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
    let size = (attributes[.size] as? NSNumber)?.intValue ?? 0
    guard size > 0, size <= 32 * 1_024 * 1_024, size.isMultiple(of: 2) else {
        throw ReplyCommandError.invalid("PCM16 input must be nonempty, even-length, and at most 32 MiB")
    }
    let handle = try FileHandle(forReadingFrom: url)
    defer { try? handle.close() }
    let segmentBytes = 48 * 1_024
    var current = try handle.read(upToCount: segmentBytes) ?? Data()
    var sequence = 0
    var deliveries = 0
    while !current.isEmpty {
        let next = try handle.read(upToCount: segmentBytes) ?? Data()
        let payload = AudioPayload(
            codec: .pcm16, sampleRate: sampleRate, channels: 1, sequence: sequence,
            streamID: streamID, isFinal: next.isEmpty, bytes: current, reply: descriptor
        )
        let frame = Frame(
            timestamp: replyTimestamp(), target: descriptor.targetID, source: descriptor.hostID,
            payload: .audio(payload)
        )
        deliveries += try await LocalReplyClient.submit(frame, socketURL: socket)
        sequence += 1
        current = next
    }
    return (sequence, deliveries)
}

private func replyTimestamp() -> Int64 {
    Int64((Date().timeIntervalSince1970 * 1_000).rounded(.down))
}
