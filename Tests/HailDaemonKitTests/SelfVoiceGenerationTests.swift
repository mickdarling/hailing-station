#if os(macOS)
import Darwin
import Foundation
import Testing
@testable import HailDaemonKit

struct SelfVoiceGenerationTests {
    @Test func readerCanOpenPreviousWaveUntilTheFollowingPublish() async throws {
        let fixture = try SelfVoiceFixture()
        defer { fixture.remove() }
        let first = try await fixture.publisher.publish([voiceFixture()])
        let reader = try FileHandle(forReadingFrom: fixture.directory.appendingPathComponent(SelfVoiceManifest.name))
        defer { try? reader.close() }

        let second = try await fixture.publisher.publish([voiceFixture(revision: "2")])
        let bytes = try #require(try reader.readToEnd())
        let previous = try JSONDecoder().decode(SelfVoiceManifest.self, from: bytes)
        #expect(previous == first)
        let wave = try #require(previous.voices.first)
        #expect(try SelfVoiceWave.digest(fixture.read(wave.file)) == wave.sha256)

        _ = try await fixture.publisher.publish([])
        #expect(try fixture.names() == [SelfVoiceManifest.name, second.voices[0].file])
    }

    @Test func emptyPublishReplacesExtraKeysWithExactV1Bytes() async throws {
        let fixture = try SelfVoiceFixture()
        defer { fixture.remove() }
        _ = try await fixture.publisher.publish([])
        let file = try FileHandle(forWritingTo: fixture.directory.appendingPathComponent(SelfVoiceManifest.name))
        try file.write(contentsOf: Data(#"{"version":1,"voices":[],"extra":true}"#.utf8))
        try file.close()

        _ = try await fixture.publisher.publish([])
        #expect(try fixture.read(SelfVoiceManifest.name) == Data(#"{"version":1,"voices":[]}"#.utf8))
    }

    private struct FailsLastVoice: SelfVoiceRendering {
        func pcm(for voice: SelfVoiceConfiguration) throws -> Data {
            guard voice.id != "broken" else { throw SelfVoiceError.audio }
            return Data(count: 8 * 48_000)
        }
    }

    @Test func repeatedRenderFailuresRemoveOnlyThisAttemptsWaves() async throws {
        let fixture = try SelfVoiceFixture()
        defer { fixture.remove() }
        _ = try await fixture.publisher.publish([voiceFixture()])
        _ = try await fixture.publisher.publish([voiceFixture(revision: "2")])
        let before = try fixture.names()
        let manifest = try fixture.read(SelfVoiceManifest.name)
        let publisher = SelfVoicePublisher(directory: fixture.directory.path,
                                           renderer: FailsLastVoice(), clock: { 100 })
        for _ in 0..<3 {
            await #expect(throws: SelfVoiceError.audio) {
                try await publisher.publish([voiceFixture(), voiceFixture("two"), voiceFixture("broken")])
            }
            #expect(try fixture.names() == before)
            #expect(try fixture.read(SelfVoiceManifest.name) == manifest)
        }
    }

    @Test func sweepRemovesOnlyExactTemporaryNamesAfterCheckingAllEntries() async throws {
        let fixture = try SelfVoiceFixture()
        defer { fixture.remove() }
        _ = try await fixture.publisher.publish([])
        let uuid = "12345678-ABCD-4ABC-8ABC-0123456789AB"
        let stale = ".self-\(uuid).tmp"
        let foreign = [".self-not-a-uuid.tmp", ".self-00000000-abcd-4abc-8abc-0123456789ab.tmp",
                       ".self-\(uuid).tmp.bak", "self-00000000-0000-0000-0000-000000000000.wav"]
        let marker = Data("foreign".utf8)
        for name in [stale] + foreign {
            let url = fixture.directory.appendingPathComponent(name)
            try marker.write(to: url)
            #expect(chmod(url.path, 0o600) == 0)
        }
        let unsafe = fixture.directory.appendingPathComponent(foreign[0])
        #expect(chmod(unsafe.path, 0o620) == 0)
        await #expect(throws: SelfVoiceError.directory) { try await fixture.publisher.publish([]) }
        #expect(try fixture.names().contains(stale))

        #expect(chmod(unsafe.path, 0o600) == 0)
        _ = try await fixture.publisher.publish([]) {
            #expect(try fixture.names() == Set(foreign + [SelfVoiceManifest.name]))
        }
        for name in foreign { #expect(try fixture.read(name) == marker) }
    }
}
#endif
