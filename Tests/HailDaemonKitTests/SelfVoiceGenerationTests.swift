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

    @Test func previousManifestRetainsWaveByFilesystemIdentity() async throws {
        let fixture = try SelfVoiceFixture()
        defer { fixture.remove() }
        let first = try await fixture.publisher.publish([voiceFixture()])
        let wave = try #require(first.voices.first)
        let upper = "self-12345678-ABCD-4ABC-8ABC-0123456789AB.wav"
        let lower = upper.lowercased()
        let upperURL = fixture.directory.appendingPathComponent(upper)
        let lowerURL = fixture.directory.appendingPathComponent(lower)
        try FileManager.default.moveItem(at: fixture.directory.appendingPathComponent(wave.file), to: upperURL)
        let sameFile = FileManager.default.fileExists(atPath: lowerURL.path)
        if !sameFile { try FileManager.default.copyItem(at: upperURL, to: lowerURL) }
        let previous = SelfVoiceManifest.Voice(id: wave.id, file: lower, source: wave.source,
                                               renderedAt: wave.renderedAt, sha256: wave.sha256)
        let file = try FileHandle(forWritingTo: fixture.directory.appendingPathComponent(SelfVoiceManifest.name))
        defer { try? file.close() }
        try file.truncate(atOffset: 0)
        try file.write(contentsOf: SelfVoiceManifest(version: 1, voices: [previous]).encoded())

        _ = try await fixture.publisher.publish([])
        #expect(try fixture.names() == [SelfVoiceManifest.name, sameFile ? upper : lower])
        #expect(try SelfVoiceWave.digest(fixture.read(lower)) == wave.sha256)
    }

    @Test func emptyPublishClearsPreviousVoiceWithOverlongFilename() async throws {
        let fixture = try SelfVoiceFixture()
        defer { fixture.remove() }
        try await fixture.publisher.publish([])
        let name = String(repeating: "a", count: Int(PATH_MAX)) + ".wav"
        let voice = SelfVoiceManifest.Voice(id: "one", file: name, source: .reply,
                                            renderedAt: 0, sha256: String(repeating: "0", count: 64))
        let previous = try SelfVoiceManifest(version: 1, voices: [voice]).encoded()
        let file = try FileHandle(forWritingTo: fixture.directory.appendingPathComponent(SelfVoiceManifest.name))
        try file.write(contentsOf: previous)
        try file.close()

        try await fixture.publisher.publish([])
        #expect(try fixture.read(SelfVoiceManifest.name) == Data(#"{"version":1,"voices":[]}"#.utf8))
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
        func profileID(named name: String, at origin: URL) -> String { name }

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

    @Test func rollbackPreservesReplacementAndRemovesOtherInstalledWave() async throws {
        enum Interrupted: Error { case beforeManifest }
        let fixture = try SelfVoiceFixture()
        defer { fixture.remove() }
        let replacement = fixture.root.appendingPathComponent("replacement")
        let marker = Data("replacement".utf8)
        try marker.write(to: replacement)
        await #expect(throws: Interrupted.beforeManifest) {
            try await fixture.publisher.publish([voiceFixture(), voiceFixture("two")]) {
                let waves = try fixture.names().filter { $0.hasSuffix(".wav") }
                try #require(waves.count == 2)
                let name = try #require(waves.sorted().first)
                let target = fixture.directory.appendingPathComponent(name)
                try #require(rename(replacement.path, target.path) == 0)
                throw Interrupted.beforeManifest
            }
        }
        let remaining = try fixture.names()
        #expect(remaining.count == 1)
        let survivor = try #require(remaining.first)
        #expect(try fixture.read(survivor) == marker)
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
            // A single-expression hook closure is type-checked as non-throwing here; a failed read yields [] and fails the expectation.
            #expect((try? fixture.names()) ?? [] == Set(foreign + [SelfVoiceManifest.name]))
        }
        for name in foreign { #expect(try fixture.read(name) == marker) }
    }
}

extension SelfVoiceGenerationTests {
    @Test(arguments: [false, true])
    func finishedPublicationUnlocksEvenWithADuplicateDescriptor(throwBeforeCommit: Bool) async throws {
        enum Interrupted: Error { case beforeCommit(Int32) }
        let fixture = try SelfVoiceFixture()
        defer { fixture.remove() }
        let retained: Int32
        do {
            retained = try await fixture.publisher.withLockedDirectory { _, directory in
                let contender = open(directory.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
                try #require(contender >= 0)
                defer { close(contender) }
                let result = flock(contender, LOCK_EX | LOCK_NB), lockError = errno
                try #require(result == -1 && lockError == EWOULDBLOCK)
                // Model an inherited open-file description without forking the parallel test process.
                let copy = fcntl(directory.descriptor, F_DUPFD_CLOEXEC, 0)
                try #require(copy >= 0)
                if throwBeforeCommit { throw Interrupted.beforeCommit(copy) }
                return copy
            }
            #expect(!throwBeforeCommit)
        } catch Interrupted.beforeCommit(let copy) {
            retained = copy
            #expect(throwBeforeCommit)
        }
        defer { close(retained) }
        let next = SelfVoicePublisher(directory: fixture.directory.path, renderer: fixture.renderer)
        let manifest = try await next.publish([])
        #expect(try fixture.read(SelfVoiceManifest.name) == manifest.encoded())
    }
}
#endif
