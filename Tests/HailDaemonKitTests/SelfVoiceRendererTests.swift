#if os(macOS)
import Foundation
import Testing
@testable import HailDaemonKit

struct SelfVoiceRendererTests {
    @Test func resamplesKnownToneAtBothDurationLimits() throws {
        for seconds in [8, 20] {
            // One 1 kHz period at 24 kHz. A sample-rate relabel changes its pitch and byte count.
            let period = (0..<24).map { Int16(8_000 * sin(2 * Double.pi * Double($0) / 24)).littleEndian }
            let samples = Array(repeating: period, count: seconds * 1_000).flatMap { $0 }
            let wav = try SelfVoiceWave.encode(samples.withUnsafeBytes { Data($0) })
            func field(_ offset: Int, _ count: Int) -> Int {
                (0..<count).reduce(0) { $0 | Int(wav[offset + $1]) << (8 * $1) }
            }
            #expect(String(bytes: wav.prefix(4), encoding: .utf8) == "RIFF")
            #expect(String(bytes: wav[8..<16], encoding: .utf8) == "WAVEfmt ")
            #expect(String(bytes: wav[36..<40], encoding: .utf8) == "data")
            #expect(field(4, 4) == wav.count - 8)
            #expect(field(16, 4) == 16)
            #expect(field(20, 2) == 1 && field(22, 2) == 1)
            #expect(field(24, 4) == 16_000 && field(28, 4) == 32_000)
            #expect(field(32, 2) == 2 && field(34, 2) == 16)
            #expect(field(40, 4) == seconds * 32_000 && wav.count == seconds * 32_000 + 44)
            let window = (1_600..<3_200).map { Int16(bitPattern: UInt16(field(44 + $0 * 2, 2))) }
            let crossings = zip(window, window.dropFirst()).filter { $0.0 < 0 && $0.1 >= 0 }
            #expect((99...101).contains(crossings.count))
            #expect(window.contains { $0 > 6_000 })
        }
    }

    @Test func refusesMalformedShortLongAndOversizeAudio() {
        for size in [0, 8 * 48_000 - 2, 8 * 48_000 + 1, 20 * 48_000 + 2] {
            #expect(throws: SelfVoiceError.audio) { try SelfVoiceWave.encode(Data(count: size)) }
        }
        for size in [8 * 32_000 - 2, 20 * 32_000 + 2, 1_000_000 - 44 + 1] {
            #expect(throws: SelfVoiceError.audio) { try SelfVoiceWave.wrap(Data(count: size)) }
        }
    }

    @Test func requiresUniqueExactProfileAndExplicitLocalReplyEngine() throws {
        let profiles: [SelfVoiceRenderer.Profile] = [.init(id: "1", name: "Local (one)"),
                                                    .init(id: "2", name: "Local (two)")]
        #expect(try SelfVoiceRenderer.exactID(named: "Local (one)", in: profiles) == "1")
        for name in ["Local", "local (one)", "Missing", ""] {
            #expect(throws: SelfVoiceError.configuration) { try SelfVoiceRenderer.exactID(named: name, in: profiles) }
        }
        #expect(throws: SelfVoiceError.configuration) {
            try SelfVoiceRenderer.exactID(named: "Local (one)", in: profiles + [.init(id: "3", name: profiles[0].name)])
        }
        for endpoint in ["https://remote.invalid", "http://127.0.0.1:80@remote.invalid", "http://localhost:80",
                         "http://127.0.0.1:80/path", "http://127.0.0.1:65536"] {
            #expect(throws: SelfVoiceError.configuration) { try voiceFixture(endpoint: endpoint).origin() }
        }
        for source in [SelfVoiceConfiguration.Source.ack, .deviceCue] {
            #expect(throws: SelfVoiceError.configuration) { try voiceFixture(source: source).origin() }
        }
        for profile in ["", " ", " name", "bad\nname"] {
            #expect(throws: SelfVoiceError.configuration) { try voiceFixture(profile: profile).origin() }
        }
        #expect(throws: SelfVoiceError.configuration) { try voiceFixture(revision: "").origin() }
    }
}
#endif
