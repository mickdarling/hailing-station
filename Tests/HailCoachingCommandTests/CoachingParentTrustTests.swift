import Darwin
import Foundation
import Security
import Testing
@testable import haild

/// Fail-closed parent verification for `haild coaching --parent-control` (#645). The pinned "app" here is this
/// test process itself: it is built with the tests, and a socketpair it creates carries its own audit token.
@Suite(.serialized) struct CoachingParentTrustTests {
    @Test func aMatchingPinOnASocketpairIsAccepted() throws {
        let fixture = try Fixture()
        try CoachingParentTrust.write(try selfPin(), to: fixture.pin)
        let pair = try SocketPair()
        defer { pair.close() }
        try CoachingParentTrust.verifyPeer(of: pair.child, pinFile: fixture.pin)
    }

    @Test func aPlainPipeOrFIFOIsRefusedEvenWithAMatchingPin() throws {
        let fixture = try Fixture()
        try CoachingParentTrust.write(try selfPin(), to: fixture.pin)
        var descriptors: [Int32] = [-1, -1]
        try #require(pipe(&descriptors) == 0)
        defer { close(descriptors[0]); close(descriptors[1]) }
        #expect(throws: CoachingCommandError.localControlRequired) {
            try CoachingParentTrust.verifyPeer(of: descriptors[0], pinFile: fixture.pin)
        }
        let fifo = fixture.root.appendingPathComponent("fifo")
        try #require(mkfifo(fifo.path, 0o600) == 0)
        let fd = open(fifo.path, O_RDONLY | O_NONBLOCK)
        try #require(fd >= 0)
        defer { close(fd) }
        #expect(throws: CoachingCommandError.localControlRequired) {
            try CoachingParentTrust.verifyPeer(of: fd, pinFile: fixture.pin)
        }
    }

    @Test func aSocketpairFromAnUnpinnedProcessIsRefused() throws {
        let fixture = try Fixture()
        let mine = try selfPin()
        for other in [CoachingTrustedApp(identifier: "com.example.authored-other", cdhash: mine.cdhash, teamID: nil),
                      CoachingTrustedApp(identifier: mine.identifier, cdhash: String(repeating: "0", count: 40),
                                         teamID: nil),
                      CoachingTrustedApp(identifier: mine.identifier, cdhash: nil, teamID: "AUTHORED00")] {
            try CoachingParentTrust.write(other, to: fixture.pin)
            let pair = try SocketPair()
            defer { pair.close() }
            #expect(throws: CoachingCommandError.localControlRequired) {
                try CoachingParentTrust.verifyPeer(of: pair.child, pinFile: fixture.pin)
            }
        }
    }

    @Test func aMissingSharedACLdOrMalformedPinIsRefused() throws {
        let pair = try SocketPair()
        defer { pair.close() }
        let missing = try Fixture()
        #expect(throws: CoachingCommandError.localControlRequired) {
            try CoachingParentTrust.verifyPeer(of: pair.child, pinFile: missing.pin)
        }
        let shared = try Fixture()
        try CoachingParentTrust.write(try selfPin(), to: shared.pin)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: shared.pin.path)
        #expect(throws: CoachingCommandError.localControlRequired) {
            try CoachingParentTrust.verifyPeer(of: pair.child, pinFile: shared.pin)
        }
        let acl = try Fixture()
        try CoachingParentTrust.write(try selfPin(), to: acl.pin)
        let permission = Process()
        permission.executableURL = URL(fileURLWithPath: "/bin/chmod")
        permission.arguments = ["+a", "everyone allow read", acl.pin.path]
        try permission.run(); permission.waitUntilExit()
        try #require(permission.terminationStatus == 0)
        #expect(throws: CoachingCommandError.localControlRequired) {
            try CoachingParentTrust.verifyPeer(of: pair.child, pinFile: acl.pin)
        }
        let malformed = try Fixture()
        let fd = open(malformed.pin.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        try #require(fd >= 0)
        _ = Data("not-json".utf8).withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        close(fd)
        #expect(throws: CoachingCommandError.localControlRequired) {
            try CoachingParentTrust.verifyPeer(of: pair.child, pinFile: malformed.pin)
        }
    }

    @Test func pinsCannotInjectIntoTheRequirement() {
        let hash = String(repeating: "a", count: 40)
        #expect(CoachingTrustedApp(identifier: "a\" or true or identifier \"b", cdhash: hash, teamID: nil)
            .requirement == nil)
        #expect(CoachingTrustedApp(identifier: "com.example.a", cdhash: "zz", teamID: nil).requirement == nil)
        #expect(CoachingTrustedApp(identifier: "com.example.a", cdhash: hash, teamID: "TEAM00000A").requirement == nil)
        #expect(CoachingTrustedApp(identifier: "com.example.a", cdhash: nil, teamID: "team\"").requirement == nil)
        #expect(CoachingTrustedApp(identifier: "com.example.a", cdhash: nil, teamID: nil).requirement == nil)
        #expect(CoachingTrustedApp(identifier: "com.example.a", cdhash: hash, teamID: nil).requirement != nil)
    }

    @Test func trustAppRefusesWithoutATerminalOrAbsolutePath() throws {
        let fixture = try Fixture()
        #expect(throws: CoachingCommandError.localControlRequired) {
            try CoachingParentTrust.trustApp(["relative.app"], pinFile: fixture.pin)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.pin.path))
    }

    private func selfPin() throws -> CoachingTrustedApp {
        var code: SecCode?, staticCode: SecStaticCode?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else {
            throw CoachingCommandError.localControlRequired
        }
        return try CoachingParentTrust.pin(for: staticCode)
    }

    private struct Fixture {
        let root: URL
        var pin: URL { root.appendingPathComponent(CoachingTrustedApp.fileName) }
        init() throws {
            root = FileManager.default.temporaryDirectory
                .appendingPathComponent("hailing-coaching-trust-\(UUID().uuidString)")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
    }

    private struct SocketPair {
        let parent: Int32, child: Int32
        init() throws {
            var descriptors: [Int32] = [-1, -1]
            guard socketpair(AF_UNIX, SOCK_STREAM, 0, &descriptors) == 0 else {
                throw CoachingCommandError.localControlRequired
            }
            parent = descriptors[0]; child = descriptors[1]
        }
        func close() { Darwin.close(parent); Darwin.close(child) }
    }
}
