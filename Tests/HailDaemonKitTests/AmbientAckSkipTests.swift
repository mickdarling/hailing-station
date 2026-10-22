#if os(macOS)
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// A clip file the library passes over is counted by reason in the `ambient_ack_clips` startup detail, so a recording
/// over one audio frame is never skipped in silence. Counts and reason tokens only. Synthetic audio only.
@Suite(.frozenGuardBudget) struct AmbientAckSkipTests {
    /// A canonical mono 16-bit WAV of `bytes` of silence at `rate`.
    static func wav(bytes: Int, rate: Int = 24000) -> Data {
        func le32(_ value: Int) -> [UInt8] { (0..<4).map { UInt8((value >> (8 * $0)) & 0xFF) } }
        func le16(_ value: Int) -> [UInt8] { (0..<2).map { UInt8((value >> (8 * $0)) & 0xFF) } }
        let fmt = le16(1) + le16(1) + le32(rate) + le32(rate * 2) + le16(2) + le16(16)
        let body = Array("WAVE".utf8) + Array("fmt ".utf8) + le32(16) + fmt + Array("data".utf8) + le32(bytes)
            + [UInt8](repeating: 0, count: bytes)
        return Data(Array("RIFF".utf8) + le32(body.count) + body)
    }

    @Test func anOversizedOrMalformedClipIsCountedNotSilent() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ack-skip-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let persona = root.appendingPathComponent("jarvis"), duck = root.appendingPathComponent("confirm-duck-on")
        for folder in [persona, duck] {
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        try Self.wav(bytes: 4800).write(to: persona.appendingPathComponent("ok.wav"))
        try Data("not audio".utf8).write(to: persona.appendingPathComponent("junk.wav"))
        try Self.wav(bytes: PayloadLimits.maxAudioBytes + 2).write(to: duck.appendingPathComponent("long.wav"))
        let library = AmbientAckLibrary(directory: root)
        #expect(library.skipped == [.tooLarge: 1, .badFormat: 1])
        #expect(library.startupDetail == "personas=1 clips=1 reserved=0 skipped=2 too_large=1 bad_format=1")
        #expect(library.nextReserved(AmbientStopConfirmation.duckOn) == nil)
    }

    /// #804: a `.wav` that is not a regular file (a FIFO, never opened) is `unreadable`, and one over the 1 MiB read
    /// cap is `too_large` before it is read, not mistaken for an unreadable one.
    @Test(.timeLimit(.minutes(1))) func aFifoIsUnreadableAndAFileOverTheReadCapIsTooLarge() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ack-skip-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let persona = root.appendingPathComponent("jarvis")
        try FileManager.default.createDirectory(at: persona, withIntermediateDirectories: true)
        try Self.wav(bytes: 4800).write(to: persona.appendingPathComponent("ok.wav"))
        #expect(mkfifo(persona.appendingPathComponent("pipe.wav").path, 0o600) == 0)
        try Data(count: 1_048_577).write(to: persona.appendingPathComponent("huge.wav"))
        let library = AmbientAckLibrary(directory: root)
        #expect(library.skipped == [.unreadable: 1, .tooLarge: 1])
        #expect(library.startupDetail == "personas=1 clips=1 reserved=0 skipped=2 too_large=1 unreadable=1")
    }

    @Test func aCleanLibraryKeepsTheShortDetail() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("ack-skip-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let duck = root.appendingPathComponent("confirm-duck-on")
        try FileManager.default.createDirectory(at: duck, withIntermediateDirectories: true)
        try Self.wav(bytes: PayloadLimits.maxAudioBytes).write(to: duck.appendingPathComponent("fits.wav"))
        let library = AmbientAckLibrary(directory: root)
        #expect(library.startupDetail == "personas=0 clips=0 reserved=1")
    }
}
#endif
