import Darwin
import Foundation
import Testing
@testable import haild
@testable import HailCoaching

@Suite struct CoachingProfileFileTests {
    @Test func privateBoundedRegularProfileLoadsWithoutRuntimeActivation() throws {
        let fixture = try Fixture()
        #expect(try fixture.configuration.loadProfile() == fixture.data)
    }
    @Test func whitespaceOnlyMatchingListenerAndProfileAreRefusedBeforeComposition() throws {
        for listener in [" ", "   "] {
            let fixture = try Fixture()
            let text = try #require(String(data: fixture.data, encoding: .utf8))
            try Data(text.replacingOccurrences(of: "private-coach", with: listener).utf8).write(to: fixture.path)
            let invalid = CoachingConfiguration(executable: fixture.configuration.executable,
                config: fixture.configuration.config, profile: fixture.path,
                outputRoot: fixture.configuration.outputRoot, listenerID: listener,
                privateOutput: 101, roomMicrophone: 102)
            #expect(throws: CoachingCommandError.invalidConfiguration) { try invalid.loadProfile() }
        }
    }
    @Test func extendedSharingACLIsRefusedEvenWithOwnerOnlyModeBits() throws {
        let fixture = try Fixture()
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: fixture.root.path)
        let permission = Process()
        permission.executableURL = URL(fileURLWithPath: "/bin/chmod")
        permission.arguments = ["+a", "everyone allow read", fixture.path.path]
        try permission.run(); permission.waitUntilExit()
        guard permission.terminationStatus == 0 else { throw CoachingCommandError.invalidConfiguration }
        var details = stat()
        #expect(stat(fixture.path.path, &details) == 0 && details.st_mode & 0o777 == 0o600)
        #expect(throws: CoachingCommandError.invalidConfiguration) { try fixture.configuration.loadProfile() }
        // Authored shared diagnostic fixture remains preserved; no real user profile is touched.
    }
    @Test func symlinkFIFOSharedEmptyOversizedAndMalformedProfilesAreRefused() throws {
        for invalid in ["symlink", "fifo", "shared", "empty", "oversized", "malformed", "wrong-listener"] {
            let fixture = try Fixture()
            switch invalid {
            case "symlink":
                let link = fixture.root.appendingPathComponent("link")
                try FileManager.default.createSymbolicLink(at: link, withDestinationURL: fixture.path)
                #expect(throws: CoachingCommandError.invalidConfiguration) {
                    try fixture.configuration(profile: link).loadProfile()
                }
                continue
            case "fifo":
                let fifo = fixture.root.appendingPathComponent("fifo")
                #expect(mkfifo(fifo.path, 0o600) == 0)
                #expect(throws: CoachingCommandError.invalidConfiguration) {
                    try fixture.configuration(profile: fifo).loadProfile()
                }
                continue
            case "shared":
                try FileManager.default.setAttributes([.posixPermissions: 0o640], ofItemAtPath: fixture.path.path)
            case "empty": try Data().write(to: fixture.path)
            case "oversized": try Data(repeating: 32, count: 7_001).write(to: fixture.path)
            case "malformed": try Data("not-json".utf8).write(to: fixture.path)
            default:
                let text = try #require(String(data: fixture.data, encoding: .utf8))
                try Data(text.replacingOccurrences(
                    of: "private-coach", with: "another-coach").utf8).write(to: fixture.path)
            }
            #expect(throws: CoachingCommandError.invalidConfiguration) { try fixture.configuration.loadProfile() }
        }
    }

    /// Authored owner-private diagnostic scratch retained, including failed cases. No device query.
    private struct Fixture {
        let root: URL, path: URL, data: Data
        var configuration: CoachingConfiguration { configuration(profile: path) }
        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent("hailing-coaching-profile-\(UUID())")
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                   attributes: [.posixPermissions: 0o700])
            path = root.appendingPathComponent("profile")
            data = try JSONSerialization.data(withJSONObject: ["version": 1, "listener_id": "private-coach",
                "name": "Coach", "domain": "Authored", "speak_when": "Pause", "stay_quiet_when": "Busy",
                "delivery": "owner_private", "priority": 0, "cooldown_ms": 0])
            try data.write(to: path)
            try FileManager.default.setAttributes([.posixPermissions: 0o600],
                                                 ofItemAtPath: path.path)
        }
        func configuration(profile: URL) -> CoachingConfiguration {
            .init(executable: root.appendingPathComponent("unused-child"),
                  config: root.appendingPathComponent("unused"),
                  profile: profile, outputRoot: root.appendingPathComponent("unused-output"),
                  listenerID: "private-coach", privateOutput: 101, roomMicrophone: 102)
        }
    }
}
