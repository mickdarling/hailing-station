#if os(macOS)
import CryptoKit
import Darwin
import Foundation
import Testing
@testable import HailDaemonKit

func voiceFixture(_ id: String = "one", profile: String = "Local (one)", revision: String = "1",
                  source: SelfVoiceConfiguration.Source = .reply,
                  endpoint: String = "http://127.0.0.1:1234") -> SelfVoiceConfiguration {
    .init(id: id, profile: profile, source: source, revision: revision, endpoint: endpoint)
}

actor SyntheticSelfVoice: SelfVoiceRendering {
    private(set) var calls: [String] = []
    private var profiles: [SelfVoiceRenderer.Profile] = [.init(id: "1", name: "Local (one)"),
                                                         .init(id: "2", name: "Local (two)")]
    func addProfile(id: String, name: String) {
        profiles.append(.init(id: id, name: name))
    }

    func replaceProfile(named name: String, id: String) {
        profiles.removeAll { $0.name == name }
        addProfile(id: id, name: name)
    }

    func profileID(named name: String, at origin: URL) throws -> String {
        try SelfVoiceRenderer.exactID(named: name, in: profiles)
    }

    func pcm(for voice: SelfVoiceConfiguration) -> Data {
        calls.append(voice.id)
        return Data(count: 8 * 48_000)
    }
}

struct SelfVoiceFixture {
    let root: URL, directory: URL
    let renderer = SyntheticSelfVoice()
    let publisher: SelfVoicePublisher

    init() throws {
        // Foundation keeps the /var symlink; the publisher refuses symlinked ancestors, so use the kernel path.
        guard let resolved = realpath(FileManager.default.temporaryDirectory.path, nil) else {
            throw CocoaError(.fileNoSuchFile)
        }
        defer { free(resolved) }
        let temp = URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
        root = temp.appendingPathComponent(UUID().uuidString)
        directory = root.appendingPathComponent("clips")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        publisher = SelfVoicePublisher(directory: directory.path, renderer: renderer, clock: { 100 })
    }

    func remove() { try? FileManager.default.removeItem(at: root) }
    func read(_ name: String) throws -> Data { try Data(contentsOf: directory.appendingPathComponent(name)) }
    func names() throws -> Set<String> { Set(try FileManager.default.contentsOfDirectory(atPath: directory.path)) }
}

struct SelfVoiceManifestTests {
    @Test func manifestBytesMatchContractAndOwnedWaveDigest() async throws {
        let fixture = try SelfVoiceFixture()
        defer { fixture.remove() }
        _ = try await fixture.publisher.publish([voiceFixture("ID_9-x")])
        let bytes = try fixture.read("manifest.json")
        let json = try #require(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        #expect(Set(json.keys) == ["version", "voices"] && json["version"] as? Int == 1)
        let entries = try #require(json["voices"] as? [[String: Any]])
        let entry = try #require(entries.first)
        #expect(entries.count == 1 && bytes.count <= 16_384)
        #expect(Set(entry.keys) == ["id", "file", "source", "rendered_at", "sha256"])
        #expect(entry["id"] as? String == "ID_9-x" && entry["source"] as? String == "reply")
        #expect(entry["rendered_at"] as? Int == 100)
        let file = try #require(entry["file"] as? String)
        #expect(file.hasSuffix(".wav") && !file.contains("/") && !file.contains(".."))
        let digest = SHA256.hash(data: try fixture.read(file)).map { String(format: "%02x", $0) }.joined()
        #expect(entry["sha256"] as? String == digest)
        #expect(try fixture.names() == ["manifest.json", file])
        for (url, mode) in [(fixture.directory, 0o700), (fixture.directory.appendingPathComponent(file), 0o600),
                            (fixture.directory.appendingPathComponent("manifest.json"), 0o600)] {
            var item = stat()
            #expect(lstat(url.path, &item) == 0)
            #expect(item.st_mode & 0o7777 == mode_t(mode) && item.st_uid == getuid())
        }
    }

    @Test func onlyChangedProfilesRenderAndRemovalRetiresOldClips() async throws {
        let fixture = try SelfVoiceFixture()
        defer { fixture.remove() }
        let publisher = fixture.publisher
        let first = try await publisher.publish([voiceFixture(), voiceFixture("two")])
        let unchanged = try await publisher.publish([voiceFixture(), voiceFixture("two")])
        #expect(first == unchanged)
        let second = try await publisher.publish([voiceFixture(revision: "2"), voiceFixture("two")])
        #expect(second.voices[0].renderedAt > first.voices[0].renderedAt)
        #expect(second.voices[0].file != first.voices[0].file && second.voices[1] == first.voices[1])
        let third = try await publisher.publish([voiceFixture(profile: "Local (two)", revision: "2")])
        #expect(third.voices[0].renderedAt > second.voices[0].renderedAt)
        #expect(try fixture.names() == Set(second.voices.map(\.file) + [third.voices[0].file, "manifest.json"]))
        let calls = await fixture.renderer.calls
        #expect(calls == ["one", "two", "one", "one"])
        let empty = try await publisher.publish([])
        #expect(empty.voices.isEmpty && empty.version == 1)
        #expect(try fixture.names() == [third.voices[0].file, "manifest.json"])
        let restart = SelfVoicePublisher(directory: fixture.directory.path, renderer: fixture.renderer, clock: { 99 })
        let restored = try await restart.publish([voiceFixture()])
        #expect(restored.voices[0].renderedAt > third.voices[0].renderedAt)
        let next = SelfVoicePublisher(directory: fixture.directory.path, renderer: fixture.renderer, clock: { 99 })
        let regenerated = try await next.publish([voiceFixture()])
        #expect(regenerated.voices[0].renderedAt > restored.voices[0].renderedAt)
    }

    @Test func limitsIDsBareNamesAndEncodedSize() throws {
        let ids = (0..<16).map { String($0) }
        try SelfVoiceManifest.checkIDs(ids)
        try SelfVoiceManifest.checkIDs([String(repeating: "a", count: 64)])
        let tooLong = String(repeating: "a", count: 65)
        let invalidIDs = [ids + ["16"], ["x", "x"], [""], ["x/y"], ["élan"], ["a\n"], [tooLong]]
        for invalid in invalidIDs {
            #expect(throws: SelfVoiceError.manifest) { try SelfVoiceManifest.checkIDs(invalid) }
        }
        let hash = String(repeating: "f", count: 64)
        for file in ["../old.wav", "sub/one.wav", "a..b.wav", "file", String(repeating: "a", count: 16_384) + ".wav"] {
            let entry = SelfVoiceManifest.Voice(id: "x", file: file, source: .reply, renderedAt: 0, sha256: hash)
            #expect(throws: SelfVoiceError.manifest) { try SelfVoiceManifest(version: 1, voices: [entry]).encoded() }
        }
    }

    @Test func invalidEnrollmentRefusesWholeListBeforeRendering() async throws {
        let fixture = try SelfVoiceFixture()
        defer { fixture.remove() }
        let remote = voiceFixture("two", endpoint: "https://remote.invalid")
        await #expect(throws: SelfVoiceError.configuration) {
            try await fixture.publisher.publish([voiceFixture(), remote])
        }
        await #expect(throws: SelfVoiceError.manifest) {
            try await fixture.publisher.publish([voiceFixture(), voiceFixture()])
        }
        let calls = await fixture.renderer.calls
        #expect(calls.isEmpty)
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.path))
    }

    @Test(arguments: [false, true])
    func ambiguousSecondProfileRefusesPublication(withCache: Bool) async throws {
        let fixture = try SelfVoiceFixture()
        defer { fixture.remove() }
        let voices = [voiceFixture(), voiceFixture("two", profile: "Local (two)")]
        if withCache { try await fixture.publisher.publish(voices) }
        let calls = await fixture.renderer.calls
        let manifest = withCache ? try fixture.read(SelfVoiceManifest.name) : nil
        await fixture.renderer.addProfile(id: "duplicate", name: "Local (two)")

        await #expect(throws: SelfVoiceError.configuration) { try await fixture.publisher.publish(voices) }
        #expect(await fixture.renderer.calls == calls)
        if let manifest {
            #expect(try fixture.read(SelfVoiceManifest.name) == manifest)
        } else {
            #expect(!FileManager.default.fileExists(atPath: fixture.directory.path))
        }
    }

    @Test func oversizedOnDiskManifestRefusesReplacement() async throws {
        let fixture = try SelfVoiceFixture()
        defer { fixture.remove() }
        _ = try await fixture.publisher.publish([])
        let json = try fixture.read("manifest.json")
        let oversized = json + Data(repeating: 32, count: 16_385 - json.count)
        let url = fixture.directory.appendingPathComponent("manifest.json")
        let file = try FileHandle(forWritingTo: url)
        try file.write(contentsOf: oversized)
        try file.close()
        await #expect(throws: SelfVoiceError.manifest) { try await fixture.publisher.publish([voiceFixture()]) }
        #expect(try fixture.read("manifest.json") == oversized)
    }

    @Test func interruptionLeavesPreviousManifestReadableUntilRetry() async throws {
        enum Interrupted: Error { case beforeManifest }
        let fixture = try SelfVoiceFixture()
        defer { fixture.remove() }
        let old = try await fixture.publisher.publish([voiceFixture()])
        let json = try fixture.read("manifest.json"), wav = try fixture.read(old.voices[0].file)
        await #expect(throws: Interrupted.beforeManifest) {
            try await fixture.publisher.publish([voiceFixture(revision: "2")]) {
                #expect(try fixture.names().filter { $0.hasSuffix(".wav") }.count == 2)
                throw Interrupted.beforeManifest
            }
        }
        #expect(try fixture.read("manifest.json") == json)
        #expect(try fixture.read(old.voices[0].file) == wav)
        #expect(try fixture.names() == [old.voices[0].file, "manifest.json"])
        let next = try await fixture.publisher.publish([voiceFixture(revision: "2")])
        #expect(try fixture.names() == [old.voices[0].file, next.voices[0].file, "manifest.json"])
    }
}
#endif
