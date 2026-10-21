import Darwin
import Foundation
import Security
import Testing
@testable import haild

/// The pin file and `haild coaching trust-app` (#645).
@Suite(.serialized) struct CoachingParentPinTests {
    /// Review of #667: the spawner controls the environment, so HAIL_CONFIG_DIR must not choose the pin. This is
    /// the reported exploit: a pin of the caller's own signature in a directory it names.
    @Test func hailConfigDirCannotChooseThePinThatVerifyPeerUses() throws {
        let fixture = try TrustSupport.Fixture()
        try CoachingParentTrust.write(try TrustSupport.selfPin(), to: fixture.pin)
        let account = String(cString: try #require(getpwuid(getuid())?.pointee.pw_dir))
        let expected = URL(fileURLWithPath: account).appendingPathComponent(".config/hail/coaching-trusted-app.json")
        let previous = getenv("HAIL_CONFIG_DIR").map { String(cString: $0) }
        setenv("HAIL_CONFIG_DIR", fixture.root.path, 1)
        defer { if let previous { setenv("HAIL_CONFIG_DIR", previous, 1) } else { unsetenv("HAIL_CONFIG_DIR") } }
        #expect(CoachingParentTrust.pinFile() == expected)
        #expect(!CoachingParentTrust.pinFile().path.hasPrefix(fixture.root.path))
        let pair = try TrustSupport.SocketPair()
        defer { pair.close() }
        #expect(throws: CoachingParentRefusal.unverified) {
            try CoachingParentTrust.verifyPeer(of: pair.child, parent: getpid()) // The account's own pin path.
        }
    }

    @Test func pinSummaryNamesThePinnedAppForDoctorAndTheCard() throws {
        let fixture = try TrustSupport.Fixture()
        #expect(CoachingParentTrust.pinSummary(pinFile: fixture.pin) == "none pinned")
        let pin = CoachingTrustedApp(identifier: "com.example.authored", cdhash: String(repeating: "ab", count: 20),
                                     teamID: nil)
        try CoachingParentTrust.write(pin, to: fixture.pin)
        #expect(CoachingParentTrust.pinSummary(pinFile: fixture.pin) == "com.example.authored, cdhash abababababab")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: fixture.pin.path)
        #expect(CoachingParentTrust.pinSummary(pinFile: fixture.pin).hasPrefix("pin file refused"))
    }

    @Test func aMissingSharedACLdOrMalformedPinIsRefused() throws {
        let pair = try TrustSupport.SocketPair()
        defer { pair.close() }
        let missing = try TrustSupport.Fixture()
        #expect(throws: CoachingParentRefusal.unverified) {
            try CoachingParentTrust.verifyPeer(of: pair.child, pinFile: missing.pin, parent: getpid())
        }
        let shared = try TrustSupport.Fixture()
        try CoachingParentTrust.write(try TrustSupport.selfPin(), to: shared.pin)
        try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: shared.pin.path)
        #expect(throws: CoachingParentRefusal.unverified) {
            try CoachingParentTrust.verifyPeer(of: pair.child, pinFile: shared.pin, parent: getpid())
        }
        let acl = try TrustSupport.Fixture()
        try CoachingParentTrust.write(try TrustSupport.selfPin(), to: acl.pin)
        let permission = Process()
        permission.executableURL = URL(fileURLWithPath: "/bin/chmod")
        permission.arguments = ["+a", "everyone allow read", acl.pin.path]
        try permission.run(); permission.waitUntilExit()
        try #require(permission.terminationStatus == 0)
        #expect(throws: CoachingParentRefusal.unverified) {
            try CoachingParentTrust.verifyPeer(of: pair.child, pinFile: acl.pin, parent: getpid())
        }
        let malformed = try TrustSupport.Fixture()
        let fd = open(malformed.pin.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        try #require(fd >= 0)
        _ = Data("not-json".utf8).withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        close(fd)
        #expect(throws: CoachingParentRefusal.unverified) {
            try CoachingParentTrust.verifyPeer(of: pair.child, pinFile: malformed.pin, parent: getpid())
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

    @Test func trustAppRefusesWithoutATerminalOrAbsolutePath() async throws {
        let fixture = try TrustSupport.Fixture()
        await #expect(throws: CoachingParentRefusal.unverified) {
            try await CoachingParentTrust.trustApp(["relative.app"], pinFile: fixture.pin)
        }
        #expect(!FileManager.default.fileExists(atPath: fixture.pin.path))
    }

    /// Second key N1: only a `.app` signed as Hailing Station; never a shell, script host or OS app.
    @Test func trustAppPinsOnlyTheHailApp() throws {
        for path in ["/bin/zsh", "/usr/bin/osascript", "/System/Applications/TextEdit.app", "/tmp/../bin/zsh"] {
            #expect(throws: CoachingParentRefusal.unverified) { try CoachingParentTrust.hailPin(atPath: path) }
        }
        var zsh: SecStaticCode?
        try #require(SecStaticCodeCreateWithPath(URL(fileURLWithPath: "/bin/zsh") as CFURL, [], &zsh) == errSecSuccess)
        let platform = try #require(zsh)
        #expect(throws: CoachingParentRefusal.unverified) { try CoachingParentTrust.pin(for: platform) }
    }
}
