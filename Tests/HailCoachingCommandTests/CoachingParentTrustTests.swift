import Darwin
import Foundation
import Security
import Testing
@testable import haild

/// Fail-closed parent verification for `haild coaching --parent-control` (#645). The pinned "app" here is this
/// test process itself: it is built with the tests, and a socketpair it creates carries its own audit token.
@Suite(.serialized) struct CoachingParentTrustTests {
    @Test func aMatchingPinOnASocketpairIsAccepted() throws {
        let fixture = try TrustSupport.Fixture()
        try CoachingParentTrust.write(try TrustSupport.selfPin(), to: fixture.pin)
        let pair = try TrustSupport.SocketPair()
        defer { pair.close() }
        try CoachingParentTrust.verifyPeer(of: pair.child, pinFile: fixture.pin, parent: getpid())
    }

    @Test func aPlainPipeOrFIFOIsRefusedEvenWithAMatchingPin() throws {
        let fixture = try TrustSupport.Fixture()
        try CoachingParentTrust.write(try TrustSupport.selfPin(), to: fixture.pin)
        var descriptors: [Int32] = [-1, -1]
        try #require(pipe(&descriptors) == 0)
        defer { close(descriptors[0]); close(descriptors[1]) }
        #expect(throws: CoachingParentRefusal.unverified) {
            try CoachingParentTrust.verifyPeer(of: descriptors[0], pinFile: fixture.pin, parent: getpid())
        }
        let fifo = fixture.root.appendingPathComponent("fifo")
        try #require(mkfifo(fifo.path, 0o600) == 0)
        let fd = open(fifo.path, O_RDONLY | O_NONBLOCK)
        try #require(fd >= 0)
        defer { close(fd) }
        #expect(throws: CoachingParentRefusal.unverified) {
            try CoachingParentTrust.verifyPeer(of: fd, pinFile: fixture.pin, parent: getpid())
        }
    }

    @Test func aSocketpairFromAnUnpinnedProcessIsRefused() throws {
        let fixture = try TrustSupport.Fixture()
        let mine = try TrustSupport.selfPin()
        for other in [CoachingTrustedApp(identifier: "com.example.authored-other", cdhash: mine.cdhash, teamID: nil),
                      CoachingTrustedApp(identifier: mine.identifier, cdhash: String(repeating: "0", count: 40),
                                         teamID: nil),
                      CoachingTrustedApp(identifier: mine.identifier, cdhash: nil, teamID: "AUTHORED00")] {
            try CoachingParentTrust.write(other, to: fixture.pin)
            let pair = try TrustSupport.SocketPair()
            defer { pair.close() }
            #expect(throws: CoachingParentRefusal.unverified) {
                try CoachingParentTrust.verifyPeer(of: pair.child, pinFile: fixture.pin, parent: getpid())
            }
        }
    }

    /// Second key B2: the peer must be this process's parent, not just any pinned process.
    @Test func aPinnedPeerThatIsNotTheParentIsRefused() throws {
        let fixture = try TrustSupport.Fixture()
        try CoachingParentTrust.write(try TrustSupport.selfPin(), to: fixture.pin)
        let pair = try TrustSupport.SocketPair()
        defer { pair.close() }
        #expect(throws: CoachingParentRefusal.unverified) {
            try CoachingParentTrust.verifyPeer(of: pair.child, pinFile: fixture.pin, parent: getppid())
        }
    }

    /// Second key B2: a connection accepted on a named socket the attacker listens on is refused, even when the
    /// pinned process is the one that connected.
    @Test func aConnectionToANamedSocketIsRefused() throws {
        let fixture = try TrustSupport.Fixture()
        try CoachingParentTrust.write(try TrustSupport.selfPin(), to: fixture.pin)
        let path = "/tmp/hcs-\(UUID().uuidString.prefix(8))"
        defer { unlink(path) }
        let listener = socket(AF_UNIX, SOCK_STREAM, 0), client = socket(AF_UNIX, SOCK_STREAM, 0)
        defer { close(listener); close(client) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            for (index, byte) in path.utf8.enumerated() { buffer[index] = byte }
        }
        let size = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(listener, $0, size) }
        }
        try #require(bound == 0 && listen(listener, 1) == 0)
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(client, $0, size) }
        }
        try #require(connected == 0)
        let accepted = accept(listener, nil, nil)
        try #require(accepted >= 0)
        defer { close(accepted) }
        #expect(throws: CoachingParentRefusal.unverified) {
            try CoachingParentTrust.verifyPeer(of: accepted, pinFile: fixture.pin, parent: getpid())
        }
    }
}
