import Foundation
import Synchronization
import Testing
@testable import HailDaemonKit

private func sameFile(_ descriptor: Int32, as url: URL) -> Bool {
    var descriptorInfo = stat(), pathInfo = stat()
    return fstat(descriptor, &descriptorInfo) == 0 && lstat(url.path, &pathInfo) == 0
        && descriptorInfo.st_dev == pathInfo.st_dev && descriptorInfo.st_ino == pathInfo.st_ino
}

/// `~/.config/hail/policy.json` on a scratch directory: permissions, symlinks, malformed content (#41
/// item 1; the signature waits for #39 and `PolicySignatureTests`).
@Suite struct PolicyFileTests {
    let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("hail-policy-\(UUID().uuidString)", isDirectory: true)

    var dir: URL { scratch.appendingPathComponent("hail", isDirectory: true) }
    var file: PolicyFile { PolicyFile(directory: dir) }

    func mode(_ url: URL) throws -> mode_t {
        var info = stat()
        try #require(lstat(url.path, &info) == 0)
        return info.st_mode & 0o777
    }

    func cleanUp() { try? FileManager.default.removeItem(at: scratch) }

    func samplePolicy() throws -> Policy {
        var policy = Policy(deliveriesPerMinute: 12)
        try policy.allow("tmux:a", binding: "$1@1/%1:9", tier: .open, capture: true)
        return policy
    }

    @Test func nothingStoredIsTheDenyAllPolicy() throws {
        defer { cleanUp() }
        #expect(try file.load() == Policy())
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        #expect(try file.load() == Policy(), "a directory with no file is also deny-all")
    }

    @Test func saveCreatesAPrivateDirectoryAndFileThatRoundTrip() throws {
        defer { cleanUp() }
        let policy = try samplePolicy()
        try file.save(policy)
        #expect(try mode(scratch) == 0o700, "a missing parent (a fresh account's ~/.config) is created private")
        #expect(try mode(dir) == 0o700)
        #expect(try mode(file.path) == 0o600)
        #expect(try file.load() == policy)
        #expect(try Data(contentsOf: file.path).last == UInt8(ascii: "\n"))
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(leftovers == [PolicyFile.fileName], "no temp file survives a save")

        var changed = policy
        changed.deny("tmux:a")
        try file.save(changed)
        #expect(try file.load() == changed, "a second save replaces the first whole")
    }

    @Test func aParentSyncFailureFailsDirectoryCreationAndCanBeRetried() throws {
        defer { cleanUp() }
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        #expect(throws: PolicyFileError.self) {
            try file.createDirectoryIfMissing(synchronize: { sameFile($0, as: scratch) ? -1 : fsync($0) })
        }
        #expect(try mode(dir) == 0o700)
        try file.createDirectoryIfMissing()
    }

    @Test func aFailedIntermediateParentSyncIsRetriedEvenWhenTheDirectoryNowExists() throws {
        defer { cleanUp() }
        let parent = scratch.deletingLastPathComponent()
        #expect(throws: PolicyFileError.self) {
            try file.createDirectoryIfMissing(synchronize: { sameFile($0, as: parent) ? -1 : fsync($0) })
        }
        #expect(try mode(scratch) == 0o700)
        #expect(!FileManager.default.fileExists(atPath: dir.path))
        try file.createDirectoryIfMissing()
        #expect(try mode(dir) == 0o700)
    }

    @Test func updateIsOneTransactionAgainstTheFile() throws {
        defer { cleanUp() }
        let policy = try samplePolicy()
        try file.save(policy)
        // A second writer on its own descriptor, as another haild process would be: it must wait for the
        // lock, then apply its change to what the first writer stored.
        let other = PolicyFile(directory: dir)
        let otherFinished = Mutex(false)
        let writer = Thread {
            _ = try? other.update { $0.deny("tmux:a") }
            otherFinished.withLock { $0 = true }
        }
        let saved = try file.update { current in
            #expect(current == policy)
            try current.allow("tmux:b", binding: "b2")
            writer.start()
            Thread.sleep(forTimeInterval: 0.2)
            #expect(otherFinished.withLock { $0 } == false, "the second writer is held out by the lock")
        }
        #expect(saved.policy.targets.keys.sorted() == ["tmux:a", "tmux:b"])
        #expect(saved.durabilityFailure == nil)
        while !otherFinished.withLock({ $0 }) { Thread.sleep(forTimeInterval: 0.01) }
        #expect(try file.load().targets.keys.sorted() == ["tmux:b"], "both changes survive, in order")
        let untouched = try file.update { _ in }
        #expect(untouched.policy == (try file.load()))
        #expect(untouched.durabilityFailure == nil)
        #expect(throws: PolicyFormatError.emptyBinding("tmux:c")) {
            try file.update { try $0.allow("tmux:c", binding: " ") }
        }
        #expect(try file.load().targets.keys.sorted() == ["tmux:b"], "a change that throws writes nothing")
    }

    @Test func aFileOthersCanReadIsRefused() throws {
        defer { cleanUp() }
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        try file.save(try samplePolicy())
        try #require(chmod(file.path.path, 0o644) == 0)
        #expect(throws: PolicyFileError.wrongPermissions(path: file.path.path, mode: "644")) { try file.load() }
        try #require(chmod(file.path.path, 0o600) == 0)
        try #require(chmod(dir.path, 0o750) == 0)
        #expect(throws: PolicyFileError.wrongPermissions(path: dir.path, mode: "750")) { try file.load() }
        #expect(throws: PolicyFileError.wrongPermissions(path: dir.path, mode: "750")) {
            try file.save(try samplePolicy())
        }
    }

    @Test func aSymlinkInPlaceOfTheFileOrDirectoryIsRefused() throws {
        defer { cleanUp() }
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        try file.save(try samplePolicy())
        let elsewhere = scratch.appendingPathComponent("elsewhere.json")
        try FileManager.default.moveItem(at: file.path, to: elsewhere)
        try FileManager.default.createSymbolicLink(at: file.path, withDestinationURL: elsewhere)
        #expect(throws: PolicyFileError.wrongType(file.path.path)) { try file.load() }

        let linkedDir = PolicyFile(directory: scratch.appendingPathComponent("link", isDirectory: true))
        try FileManager.default.createSymbolicLink(at: linkedDir.directory, withDestinationURL: dir)
        #expect(throws: PolicyFileError.wrongType(linkedDir.directory.path)) { try linkedDir.load() }
        #expect(throws: PolicyFileError.wrongType(linkedDir.directory.path)) { try linkedDir.save(Policy()) }
    }

    @Test func aFifoInPlaceOfTheFileIsRefusedWithoutBlocking() throws {
        defer { cleanUp() }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try #require(mkfifo(file.path.path, 0o600) == 0)
        // With no writer, an open that followed the FIFO would hang every haild command; O_NONBLOCK returns.
        #expect(throws: PolicyFileError.wrongType(file.path.path)) { try file.load() }
        #expect(throws: PolicyFileError.wrongType(file.path.path)) { try file.update { _ in } }
    }

    @Test func aFileThatDoesNotParseIsRefusedNotIgnored() throws {
        defer { cleanUp() }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        for bad in ["not json", "{\"version\":1,\"extra\":true}", "{\"version\":2}", ""] {
            try Data(bad.utf8).write(to: file.path)
            try #require(chmod(file.path.path, 0o600) == 0)
            #expect(throws: PolicyFileError.self) { try file.load() }
        }
    }

    @Test func anOversizedFileIsRefusedBeforeDecoding() throws {
        defer { cleanUp() }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try Data(repeating: UInt8(ascii: " "), count: PolicyFile.maxBytes + 1).write(to: file.path)
        try #require(chmod(file.path.path, 0o600) == 0)
        #expect(throws: PolicyFileError.malformed("\(file.path.path): over 1 MiB")) { try file.load() }
    }

    @Test func standardLocationIsTheConfigDirUnlessOverridden() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        #expect(PolicyFile.standard(environment: [:]).path == home.appendingPathComponent(".config/hail/policy.json"))
        #expect(PolicyFile.standard(environment: ["HAIL_CONFIG_DIR": ""]).directory
            == home.appendingPathComponent(".config/hail", isDirectory: true))
        #expect(PolicyFile.standard(environment: ["HAIL_CONFIG_DIR": "/tmp/x"]).path.path == "/tmp/x/policy.json")
        #expect(file.summary.hasSuffix("policy.json (unsigned until #39)"))
    }
}
