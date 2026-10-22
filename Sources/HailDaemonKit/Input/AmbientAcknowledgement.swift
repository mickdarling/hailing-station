#if os(macOS)
// Addressing, clips and their library form one review boundary; skipped-clip counts pushed it past the limit.
// swiftlint:disable file_length
public import Foundation
import HailProtocol
import Synchronization

/// The names RightyO advertises in `started` (`addressing`, rightyo#105) for picking the acknowledgement voice.
/// Parsed leniently and bounded: a malformed or oversized list yields fewer names, never a refused stream.
public struct RightyoAddressing: Sendable, Equatable {
    public static let maxNames = 8, maxVariants = 32, maxLength = 48
    /// Canonical names, each with its accepted spellings (the name itself first).
    public let spellings: [String: [String]]

    public init(spellings: [String: [String]]) { self.spellings = spellings }

    init(_ value: JSONValue?) {
        guard case .object(let object) = value, case .array(let names) = object["names"] else {
            self.init(spellings: [:])
            return
        }
        var variants: [String: JSONValue] = [:]
        if case .object(let table) = object["variants"] { variants = table }
        var spellings: [String: [String]] = [:], budget = Self.maxVariants
        for case .string(let name) in names.prefix(Self.maxNames) where (1...Self.maxLength).contains(name.count) {
            var all = [name]
            if case .array(let list) = variants[name] {
                for case .string(let variant) in list where budget > 0 && (1...Self.maxLength).contains(variant.count) {
                    all.append(variant)
                    budget -= 1
                }
            }
            spellings[name] = all
        }
        self.init(spellings: spellings)
    }

    /// RightyO's name key: case-folded ASCII letters and digits only, so "Hailey," and "hailey" match.
    static func key(_ text: String) -> String {
        String(text.lowercased().unicodeScalars.filter { $0.isASCII && CharacterSet.alphanumerics.contains($0) })
    }

    /// Words as the matcher sees them, for text and spellings alike: runs of letters and digits, keyed.
    static func words(_ text: String) -> [String] {
        text.split { !($0.isLetter || $0.isNumber) }.map { key(String($0)) }
    }

    /// The persona key (the canonical name's key) of the earliest name or variant in `text`, or nil.
    public func persona(in text: String) -> String? {
        // Speech recognition may split a name ("Righty O"), so windows span up to three words at least.
        var table: [String: String] = [:], longest = 3
        for (name, all) in spellings {
            for spelling in all where !Self.key(spelling).isEmpty {
                table[Self.key(spelling)] = Self.key(name)
                longest = max(longest, Self.words(spelling).count)
            }
        }
        let words = Self.words(text)
        for start in words.indices {
            for width in 1...longest where start + width <= words.count {
                if let persona = table[words[start..<start + width].joined()] { return persona }
            }
        }
        return nil
    }
}

/// One admitted ambient request about to be typed into the pane (rightyo#105): what the acknowledgement needs,
/// tokens and counts only. `persona` is a key from the advertised names, never transcript text.
public struct AmbientAckRequest: Sendable {
    public let persona: String?
    /// RightyO's leg: emission minus the turn's end, on the producer's stream clock.
    public let rightyoMs: Int
    /// When haild read the request line, on its own clock; never compared with the producer's times.
    public let readAt: ContinuousClock.Instant
}

/// One admitted ambient request RightyO marked `acknowledge: false` (rightyo#132): no clip plays. Labels and
/// numbers only, never transcript text. `confidence` is the decision's own, which on a follow-up belongs to the
/// `uncertain` label it was promoted from, not to RightyO's attend probability.
public struct AmbientAckSkip: Sendable, Equatable {
    public let followUp: Bool
    public let confidence: Double?

    /// The `ambient_acknowledged` log detail for this skip.
    public var detail: String {
        "outcome=skipped reason=gated follow_up=\(followUp) confidence="
            + (confidence.map { String(format: "%.2f", $0) } ?? "none")
    }
}

/// Why a clip file was passed over: samples over one audio frame (`PayloadLimits.maxAudioBytes`) or a file over the
/// read cap, not mono 16-bit PCM at a supported rate, or not a readable regular file.
enum AmbientClipSkip: String, Error, CaseIterable, Sendable {
    case tooLarge = "too_large", badFormat = "bad_format", unreadable
}

/// One pre-recorded acknowledgement: mono PCM16 small enough for a single reply audio frame.
public struct AmbientAckClip: Sendable, Equatable {
    public let pcm: Data
    public let sampleRate: Int
    public let text: String?

    /// A canonical RIFF/WAVE file of mono 16-bit PCM at a supported rate whose samples fit in one audio frame.
    static func wav(_ data: Data, text: String?) -> AmbientAckClip? { try? parse(data, text: text).get() }

    /// `wav`, saying why a file is not a clip: samples over one audio frame are `tooLarge`, anything else `badFormat`.
    static func parse(_ data: Data, text: String?) -> Result<AmbientAckClip, AmbientClipSkip> {
        let bytes = [UInt8](data)
        func u32(_ at: Int) -> Int {
            Int(bytes[at]) | Int(bytes[at + 1]) << 8 | Int(bytes[at + 2]) << 16 | Int(bytes[at + 3]) << 24
        }
        func u16(_ at: Int) -> Int { Int(bytes[at]) | Int(bytes[at + 1]) << 8 }
        guard bytes.count >= 12, bytes[0..<4] == [0x52, 0x49, 0x46, 0x46], bytes[8..<12] == [0x57, 0x41, 0x56, 0x45]
        else { return .failure(.badFormat) }
        var offset = 12, rate: Int?, pcm: Data?
        while offset + 8 <= bytes.count {
            let id = bytes[offset..<offset + 4], size = u32(offset + 4), body = offset + 8
            guard size >= 0, body + size <= bytes.count else { return .failure(.badFormat) }
            if id == [0x66, 0x6D, 0x74, 0x20] {
                guard size >= 16, u16(body) == 1, u16(body + 2) == 1, u16(body + 14) == 16 else {
                    return .failure(.badFormat)
                }
                rate = u32(body + 4)
            } else if id == [0x64, 0x61, 0x74, 0x61] {
                pcm = data.subdata(in: body..<body + size)
            }
            offset = body + size + (size & 1)
        }
        guard let rate, PayloadLimits.sampleRates.contains(rate), let pcm, !pcm.isEmpty, pcm.count.isMultiple(of: 2)
        else { return .failure(.badFormat) }
        guard pcm.count <= PayloadLimits.maxAudioBytes else { return .failure(.tooLarge) }
        return .success(AmbientAckClip(pcm: pcm, sampleRate: rate, text: text))
    }
}

/// Acknowledgement clips by persona key, loaded once from `<directory>/<persona>/*.wav` (with an optional
/// `<clip>.txt` holding the spoken words). Clips are local files, never part of the repository. Unreadable or
/// unsupported files are skipped; each persona rotates through its clips without repeating the last one. The reserved
/// confirmation folders (#418, `AmbientStopConfirmation.reserved`) load beside the personas, outside their cap, and
/// are never an acknowledgement voice: `clips` holds the personas only.
public final class AmbientAckLibrary: Sendable {
    public static let maxPersonas = 8, maxClipsPerPersona = 16
    public let clips: [String: [AmbientAckClip]]
    /// Confirmation clips by reserved key; never chosen for an acknowledgement.
    let reserved: [String: [AmbientAckClip]]
    private let lastPlayed = Mutex<[String: Int]>([:])
    /// `.wav` files the directory load passed over, by reason: counts only, for the startup log.
    let skipped: [AmbientClipSkip: Int]

    /// Reserved keys in `clips` are taken as confirmation clips, not personas.
    public convenience init(clips: [String: [AmbientAckClip]]) { self.init(clips: clips, skipped: [:]) }

    init(clips: [String: [AmbientAckClip]], skipped: [AmbientClipSkip: Int]) {
        self.clips = clips.filter { !AmbientStopConfirmation.reserved.contains($0.key) }
        reserved = clips.filter { AmbientStopConfirmation.reserved.contains($0.key) }
        self.skipped = skipped
    }

    public convenience init(directory: URL) {
        let files = FileManager.default
        var clips: [String: [AmbientAckClip]] = [:], reserved: [String: [AmbientAckClip]] = [:]
        var skipped: [AmbientClipSkip: Int] = [:]
        let personas = (try? files.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        for folder in personas.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            let persona = RightyoAddressing.key(folder.lastPathComponent)
            let isReserved = AmbientStopConfirmation.reserved.contains(persona)
            guard !persona.isEmpty, isReserved || clips.count < Self.maxPersonas,
                  let entries = try? files.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)
            else { continue }
            var loaded: [AmbientAckClip] = []
            for url in entries.filter({ $0.pathExtension.lowercased() == "wav" })
                .sorted(by: { $0.lastPathComponent < $1.lastPathComponent })
            where loaded.count < Self.maxClipsPerPersona {
                switch Self.clip(at: url) {
                case .success(let clip): loaded.append(clip)
                case .failure(let reason): skipped[reason, default: 0] += 1
                }
            }
            guard !loaded.isEmpty else { continue }
            if isReserved { reserved[persona] = loaded } else { clips[persona] = loaded }
        }
        self.init(clips: clips.merging(reserved) { user, _ in user }, skipped: skipped)
    }

    /// One `.wav` and its optional words, or why it is not a clip.
    private static func clip(at url: URL) -> Result<AmbientAckClip, AmbientClipSkip> {
        let limit = 1_048_576
        guard let data = read(url, limit: limit) else {
            let size = (try? url.resolvingSymlinksInPath().resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return .failure(size > limit ? .tooLarge : .unreadable)
        }
        let words = read(url.deletingPathExtension().appendingPathExtension("txt"), limit: 800)
            .flatMap { String(data: $0, encoding: .utf8) }?.trimmingCharacters(in: .whitespacesAndNewlines)
        return AmbientAckClip.parse(data, text: words.flatMap { $0.isEmpty || $0.count > 200 ? nil : $0 })
    }

    /// The `ambient_ack_clips` startup detail: counts and reason tokens only, never a file name or its words.
    var startupDetail: String {
        let total = skipped.values.reduce(0, +)
        guard total > 0 else { return summary }
        let reasons = AmbientClipSkip.allCases.compactMap { skip in skipped[skip].map { "\(skip.rawValue)=\($0)" } }
        return ([summary, "skipped=\(total)"] + reasons).joined(separator: " ")
    }

    /// A regular file's contents when it is no larger than `limit`, checked before reading: a FIFO, device or
    /// oversized file is never read.
    static func read(_ url: URL, limit: Int) -> Data? {
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .fileSizeKey]
        guard let values = try? url.resolvingSymlinksInPath().resourceValues(forKeys: keys),
              values.isRegularFile == true, let size = values.fileSize, size <= limit else { return nil }
        return try? Data(contentsOf: url)
    }

    /// The next clip for `persona` and its index, rotating and never repeating the last one; nil without clips.
    public func next(for persona: String) -> (index: Int, clip: AmbientAckClip)? {
        rotate(clips[persona], key: persona)
    }

    /// The next confirmation clip for a reserved key, rotating like a persona's.
    func nextReserved(_ key: String) -> (index: Int, clip: AmbientAckClip)? {
        rotate(reserved[key], key: key)
    }

    private func rotate(_ options: [AmbientAckClip]?, key: String) -> (index: Int, clip: AmbientAckClip)? {
        guard let options, !options.isEmpty else { return nil }
        let index = lastPlayed.withLock { last -> Int in
            let next = ((last[key] ?? -1) + 1) % options.count
            last[key] = next
            return next
        }
        return (index, options[index])
    }
}

#endif
