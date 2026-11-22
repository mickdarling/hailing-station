#if os(macOS)
import AVFAudio
import CryptoKit
import Foundation

enum SelfVoiceError: Error, Equatable { case configuration, audio, manifest, directory }

struct SelfVoiceConfiguration: Equatable, Sendable {
    enum Source: String, Codable { case reply, ack, deviceCue = "device_cue" }
    let id: String
    let profile: String
    let source: Source
    let revision: String
    /// Explicit origin of the local Voicebox engine that owns this reply profile.
    let endpoint: String

    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.id == rhs.id && lhs.source == rhs.source && lhs.endpoint == rhs.endpoint &&
            lhs.profile.utf8.elementsEqual(rhs.profile.utf8) && lhs.revision.utf8.elementsEqual(rhs.revision.utf8)
    }

    func origin() throws -> URL {
        guard source == .reply, !revision.isEmpty, !profile.isEmpty, profile.utf8.count <= 256,
              profile.trimmingCharacters(in: .whitespacesAndNewlines) == profile,
              !profile.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains),
              let parts = URLComponents(string: endpoint), let port = parts.port, (1...65535).contains(port),
              let host = parts.host, ["127.0.0.1", "[::1]"].contains(host),
              endpoint == "http://\(host):\(port)", let url = parts.url else { throw SelfVoiceError.configuration }
        return url
    }
}

/// The only input audio is renderer stdout, mono signed 16-bit little-endian PCM at 24 kHz.
protocol SelfVoiceRendering: Sendable {
    func pcm(for voice: SelfVoiceConfiguration) async throws -> Data
}

extension SelfVoiceRendering {
    func clip(for voice: SelfVoiceConfiguration, at timestamp: Int) async throws -> (SelfVoiceManifest.Voice, Data) {
        let wav = try SelfVoiceWave.encode(try await pcm(for: voice))
        let entry = SelfVoiceManifest.Voice(id: voice.id, file: "self-\(UUID().uuidString).wav", source: voice.source,
                                            renderedAt: timestamp, sha256: SelfVoiceWave.digest(wav))
        return (entry, wav)
    }
}

struct SelfVoiceRenderer: SelfVoiceRendering {
    let executable: URL
    let outputRoot: URL
    static let passage = "A sheet of paper rests on the table beside a small blue pencil. " +
        "Light passes through the window and moves across the page as the afternoon slowly turns to evening."

    func pcm(for voice: SelfVoiceConfiguration) async throws -> Data {
        let origin = try voice.origin()
        let profileID = try await Self.profileID(named: voice.profile, at: origin)
        // The shared validator checks the resolved executable AND its ancestors. The fixed env launcher
        // in OwnedReplyRenderer then finds that same vbsay first, independent of the calling shell.
        let path = try RightyoChildProcess.validate(executable: executable, config: executable) as NSString
        guard path.lastPathComponent == "vbsay", !path.contains(":") else { throw SelfVoiceError.configuration }
        // urllib sends only the loopback origin directly; HTTP(S) redirects elsewhere have no usable proxy.
        let localAuthority = String(voice.endpoint.dropFirst("http://".count))
        let environment = ["PATH": path.deletingLastPathComponent + ":/usr/bin:/bin",
                           "VBSAY_ENGINE": "voicebox", "VBSTREAM": "0", "VOICEBOX_URL": origin.absoluteString,
                           "VBSAY_PROFILE": voice.profile, "VBSAY_NOFALLBACK": "1", "no_proxy": localAuthority,
                           "http_proxy": "http://127.0.0.1:0", "https_proxy": "http://127.0.0.1:0",
                           "PYTHONNOUSERSITE": "1"]
        let child = try OwnedReplyRenderer.startForJoinedRetirement(
            text: Self.passage, outputRoot: outputRoot, environment: environment)
        let bytes = try await withTaskCancellationHandler {
            try await Self.collect(child)
        } onCancel: { child.cancel() }
        guard try await Self.profileID(named: voice.profile, at: origin) == profileID else {
            throw SelfVoiceError.configuration
        }
        return bytes
    }

    private static func collect(_ child: OwnedReplyRenderer) async throws -> Data {
        do {
            var pcm = Data()
            for try await chunk in child.audio {
                try Task.checkCancellation()
                guard chunk.count <= SelfVoiceWave.maxInput - pcm.count else { throw SelfVoiceError.audio }
                pcm.append(chunk)
            }
            try await child.requireSuccessfulExit()
            child.retire(cancel: false)
            try await child.waitForCleanup()
            return pcm
        } catch {
            child.retire(cancel: true)
            _ = try? await child.requireSuccessfulExit()
            await child.waitForCancellationSignals()
            _ = try? await child.waitForCleanup()
            throw error
        }
    }

    struct Profile: Decodable { let id: String, name: String }

    static func exactID(named name: String, in profiles: [Profile]) throws -> String {
        // Python's name equality is code-point exact. Swift String equality also accepts canonical equivalents.
        let matches = profiles.filter { $0.name.utf8.elementsEqual(name.utf8) }
        guard matches.count == 1, let id = matches.first?.id, !id.isEmpty else { throw SelfVoiceError.configuration }
        return id
    }

    private static func profileID(named name: String, at origin: URL) async throws -> String {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]
        let session = URLSession(configuration: config, delegate: LocalCatalogDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (bytes, response) = try await session.bytes(from: origin.appendingPathComponent("profiles"))
        guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw SelfVoiceError.configuration }
        var data = Data()
        for try await byte in bytes {
            guard data.count < 1_048_576 else { throw SelfVoiceError.configuration }
            data.append(byte)
        }
        return try exactID(named: name, in: JSONDecoder().decode([Profile].self, from: data))
    }
}

private final class LocalCatalogDelegate: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

enum SelfVoiceWave {
    static let maxInput = 20 * 24_000 * 2
    static let maxBytes = 1_000_000

    static func digest(_ wav: Data) -> String {
        SHA256.hash(data: wav).map { String(format: "%02x", $0) }.joined()
    }

    /// One synchronous offline conversion. Only the converter's input block accesses this cursor.
    private final class Input: @unchecked Sendable {
        var buffer: AVAudioPCMBuffer?
        init(_ buffer: AVAudioPCMBuffer) { self.buffer = buffer }
    }

    static func encode(_ pcm: Data) throws -> Data {
        guard (8 * 48_000...maxInput).contains(pcm.count), pcm.count.isMultiple(of: 2),
              let source = format(24_000), let target = format(16_000),
              let converter = AVAudioConverter(from: source, to: target),
              let buffer = AVAudioPCMBuffer(pcmFormat: source, frameCapacity: AVAudioFrameCount(pcm.count / 2)),
              let samples = buffer.int16ChannelData?[0] else { throw SelfVoiceError.audio }
        buffer.frameLength = buffer.frameCapacity
        _ = pcm.copyBytes(to: UnsafeMutableRawBufferPointer(start: samples, count: pcm.count))
        let frames = pcm.count / 3 // floor(input frames * 16/24); cap output to the reference duration.
        guard let output = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: AVAudioFrameCount(frames)) else {
            throw SelfVoiceError.audio
        }
        let input = Input(buffer)
        var error: NSError?
        let status = converter.convert(to: output, error: &error) { _, state in
            let next = input.buffer
            input.buffer = nil
            state.pointee = next == nil ? .endOfStream : .haveData
            return next
        }
        guard status != .error, error == nil, output.frameLength == frames,
              let converted = output.int16ChannelData?[0] else { throw SelfVoiceError.audio }
        return try wrap(Data(bytes: converted, count: frames * 2))
    }

    private static func format(_ rate: Double) -> AVAudioFormat? {
        AVAudioFormat(commonFormat: .pcmFormatInt16, sampleRate: rate, channels: 1, interleaved: false)
    }

    static func wrap(_ payload: Data) throws -> Data {
        guard payload.count <= maxBytes - 44, (8 * 32_000...20 * 32_000).contains(payload.count),
              payload.count.isMultiple(of: 2) else { throw SelfVoiceError.audio }
        var wav = Data("RIFF".utf8)
        func append<T: FixedWidthInteger>(_ value: T) {
            withUnsafeBytes(of: value.littleEndian) { wav.append(contentsOf: $0) }
        }
        append(UInt32(36 + payload.count))
        wav.append(contentsOf: "WAVEfmt ".utf8)
        append(UInt32(16))
        append(UInt16(1))
        append(UInt16(1))
        append(UInt32(16_000))
        append(UInt32(32_000))
        append(UInt16(2))
        append(UInt16(16))
        wav.append(contentsOf: "data".utf8)
        append(UInt32(payload.count))
        wav.append(payload)
        return wav
    }
}
#endif
