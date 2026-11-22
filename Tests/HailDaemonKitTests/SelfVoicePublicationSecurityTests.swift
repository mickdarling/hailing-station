#if os(macOS)
import Darwin
import Foundation
import Testing
@testable import HailDaemonKit

struct SelfVoicePublicationSecurityTests {
    @Test func refusesForeignUIDOrExtendedACLForDirectoriesAndRegularFiles() throws {
        // Exercise the same fstat predicate without requiring privileged chown.
        for (type, mode) in [(S_IFDIR, 0o700), (S_IFREG, 0o600)] {
            var item = stat()
            item.st_mode = mode_t(type) | mode_t(mode)
            item.st_nlink = 1
            item.st_uid = getuid()
            try SelfVoiceDirectory.requirePrivate(item, type: mode_t(type), hasACL: false)
            #expect(throws: SelfVoiceError.directory) {
                try SelfVoiceDirectory.requirePrivate(item, type: mode_t(type), hasACL: true)
            }
            item.st_uid ^= 1
            #expect(throws: SelfVoiceError.directory) {
                try SelfVoiceDirectory.requirePrivate(item, type: mode_t(type), hasACL: false)
            }
        }
    }

    @Test func checksAncestorOwnerModeStickyBitAndWritableACL() throws {
        var item = stat()
        item.st_uid = 0
        item.st_mode = S_IFDIR | 0o1777
        try SelfVoiceDirectory.requireAncestor(item, writableACL: false)
        #expect(throws: SelfVoiceError.directory) { try SelfVoiceDirectory.requireAncestor(item, writableACL: true) }
        item.st_uid = getuid()
        for mode in [0o720, 0o702] {
            item.st_mode = S_IFDIR | mode_t(mode)
            #expect(throws: SelfVoiceError.directory) {
                try SelfVoiceDirectory.requireAncestor(item, writableACL: false)
            }
        }
        item.st_mode = S_IFDIR | 0o700
        try SelfVoiceDirectory.requireAncestor(item, writableACL: false)
        item.st_uid = uid_t.max
        #expect(throws: SelfVoiceError.directory) { try SelfVoiceDirectory.requireAncestor(item, writableACL: false) }
    }

    @Test(arguments: ["ancestor", "directory", "manifest.json", "previous-wave", "foreign"])
    func rejectsACLAtEachPublicationBoundary(target: String) async throws {
        let fixture = try SelfVoiceFixture()
        defer { fixture.remove() }
        let first = try await fixture.publisher.publish([voiceFixture()])
        _ = try await fixture.publisher.publish([])
        let url: URL
        switch target {
        case "ancestor": url = fixture.root
        case "directory": url = fixture.directory
        case "previous-wave": url = fixture.directory.appendingPathComponent(first.voices[0].file)
        default: url = fixture.directory.appendingPathComponent(target)
        }
        if target == "foreign" {
            try Data().write(to: url)
            #expect(chmod(url.path, 0o600) == 0)
        }
        let entry = target == "ancestor" ? "everyone allow delete_child" : "everyone deny delete"
        try CodexLauncherTests.addACL(entry, to: url.path)
        defer { CodexLauncherTests.clearACLs(url.path) }
        await #expect(throws: SelfVoiceError.directory) { try await fixture.publisher.publish([]) }
        #expect(try fixture.names().contains(first.voices[0].file))
    }

    @Test func rejectsWritableDirectoryOrUnrelatedEntryBeforeRendering() async throws {
        let fixture = try SelfVoiceFixture()
        defer { fixture.remove() }
        _ = try await fixture.publisher.publish([])
        let original = try fixture.read("manifest.json")
        for mode in [0o720, 0o702, 0o755] {
            #expect(chmod(fixture.directory.path, mode_t(mode)) == 0)
            await #expect(throws: SelfVoiceError.directory) { try await fixture.publisher.publish([voiceFixture()]) }
        }
        #expect(chmod(fixture.directory.path, 0o700) == 0)
        let other = fixture.directory.appendingPathComponent("unrelated")
        try Data().write(to: other)
        for mode in [0o620, 0o602, 0o644] {
            #expect(chmod(other.path, mode_t(mode)) == 0)
            await #expect(throws: SelfVoiceError.directory) { try await fixture.publisher.publish([voiceFixture()]) }
        }
        let calls = await fixture.renderer.calls
        #expect(calls.isEmpty)
        #expect(try fixture.read("manifest.json") == original)
    }

    @Test func refusesRelativePathAndSymlinkedAncestor() async throws {
        let fixture = try SelfVoiceFixture()
        defer { fixture.remove() }
        let link = fixture.root.appendingPathComponent("alias")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.root)
        for path in ["relative", link.appendingPathComponent("clips").path] {
            let publisher = SelfVoicePublisher(directory: path, renderer: fixture.renderer)
            await #expect(throws: SelfVoiceError.directory) { try await publisher.publish([]) }
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.directory.path))
    }

    @Test func directorySwapAfterWaveCannotRedirectCommitOrCleanup() async throws {
        let fixture = try SelfVoiceFixture()
        defer { fixture.remove() }
        let old = try await fixture.publisher.publish([voiceFixture()])
        let json = try fixture.read("manifest.json")
        let saved = fixture.root.appendingPathComponent("saved")
        let outside = fixture.root.appendingPathComponent("other")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
        await #expect(throws: SelfVoiceError.directory) {
            try await fixture.publisher.publish([voiceFixture(revision: "2")]) {
                try FileManager.default.moveItem(at: fixture.directory, to: saved)
                try FileManager.default.createSymbolicLink(at: fixture.directory, withDestinationURL: outside)
            }
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
        #expect(try Data(contentsOf: saved.appendingPathComponent("manifest.json")) == json)
        #expect(FileManager.default.fileExists(atPath: saved.appendingPathComponent(old.voices[0].file).path))
    }

    @Test(arguments: ["manifest", "new-wave", "unrelated"])
    func entrySwapsAfterRenderRefusePublication(target: String) async throws {
        let fixture = try SelfVoiceFixture()
        defer { fixture.remove() }
        let old = try await fixture.publisher.publish([voiceFixture()])
        let json = try fixture.read("manifest.json")
        let outside = fixture.root.appendingPathComponent("outside")
        let marker = Data("fixture".utf8)
        try marker.write(to: outside)
        await #expect(throws: SelfVoiceError.directory) {
            try await fixture.publisher.publish([voiceFixture(revision: "2")]) {
                let added = try #require(fixture.names().subtracting(["manifest.json", old.voices[0].file]).first)
                let name = target == "manifest" ? "manifest.json" : (target == "new-wave" ? added : "unrelated")
                let entry = fixture.directory.appendingPathComponent(name)
                if target != "unrelated" { try FileManager.default.removeItem(at: entry) }
                try FileManager.default.createSymbolicLink(at: entry, withDestinationURL: outside)
            }
        }
        #expect(try Data(contentsOf: outside) == marker)
        if target != "manifest" { #expect(try fixture.read("manifest.json") == json) }
        #expect(try fixture.names().contains(old.voices[0].file))
    }
}
#endif
