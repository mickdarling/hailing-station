#if os(macOS)
import Darwin
import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// Privacy mode survives a restart (#735 S-2b, internally duck): a content-free 0600 state file in haild's own config
/// directory, written before an entry is confirmed and removed only after a confirmed exit. Only a missing file starts
/// public; anything else starts private, with every child launched start-private. Synthetic only.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientPrivacyPersistTests {
    /// A fresh state directory under the test scratch (never `~/.config/hail`).
    static func store() -> AmbientPrivacyState {
        AmbientPrivacyState(directory: TestScratch.url("privacy-state").appendingPathComponent("privacy"))
    }

    /// The store's file written with `body`, as a crash or another writer might leave it.
    static func plant(_ body: String, in store: AmbientPrivacyState, mode: mode_t = 0o600) throws {
        try FileManager.default.createDirectory(at: store.directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try Data(body.utf8).write(to: store.file)
        #expect(chmod(store.file.path, mode) == 0)
    }

    /// A fake that records each launch's arguments, takes control lines, and says nothing but `started` (confirming
    /// privacy when launched start-private) and `stopped`.
    static let quiet = "echo \"$*\" >> argv.txt\n/bin/cat <&3 >> control.txt &\n"
        + AmbientPrivacyEntryTests.fixture(saying: "Rightyo, archive the project.", advertises: true)
    static let entering = "echo \"$*\" >> argv.txt\n/bin/cat <&3 >> control.txt &\n" + AmbientDuckReloadTests.entry

    static func launches(_ rig: DuckRig) -> [Substring] {
        ((try? rig.fake.recorded("argv.txt")) ?? "").split(separator: "\n")
    }

    // MARK: The file

    @Test func theRecordHoldsNoWordsAndIsOwnerOnly() throws {
        let store = Self.store()
        try store.enter(since: Date(timeIntervalSince1970: 1_700_000_000))
        let body = try String(contentsOf: store.file, encoding: .utf8)
        #expect(body == "{\"private\":true,\"since\":1700000000}\n")
        var info = stat()
        #expect(stat(store.file.path, &info) == 0 && info.st_mode & 0o777 == 0o600)
        #expect(stat(store.directory.path, &info) == 0 && info.st_mode & 0o777 == 0o700)
        #expect(try FileManager.default.contentsOfDirectory(atPath: store.directory.path) == ["state.json"])
        #expect(store.read() == .private)
        try store.clear()
        try store.clear()
        #expect(store.read() == .public)
    }

    @Test(arguments: [
        "", "garbage", "{}", "[]", #"{"private":false,"since":1}"#, #"{"private":1,"since":1}"#,
        #"{"private":"true","since":1}"#, #"{"private":true}"#, #"{"private":true,"since":-1}"#,
        #"{"private":true,"since":1.5}"#, #"{"private":true,"since":true}"#,
        #"{"private":true,"since":1,"words":"stop recording"}"#, String(repeating: " ", count: 300) + "{}"
    ])
    func anythingButTheRecordIsCorruptAndReadsPrivate(_ body: String) throws {
        let store = Self.store()
        try Self.plant(body, in: store)
        #expect(store.read() == .corrupt)
    }

    @Test func anUnreadableFileReadsPrivate() throws {
        let store = Self.store()
        try Self.plant("{\"private\":true,\"since\":1}\n", in: store, mode: 0o000)
        #expect(store.read() == .unreadable)
        let directory = Self.store()
        try FileManager.default.createDirectory(at: directory.file, withIntermediateDirectories: true)
        #expect(directory.read() == .unreadable)
        let link = Self.store()
        try FileManager.default.createDirectory(at: link.directory, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: link.file.path, withDestinationPath: "/dev/null")
        #expect(link.read() == .unreadable)
    }

    @Test func onlyAMissingFileReadsPublic() {
        #expect(Self.store().read() == .public)
    }

    /// The standard place is haild's own config directory, never the shared temp folder.
    @Test func theStandardPlaceIsTheConfigDirectory() {
        let store = AmbientPrivacyState.standard(environment: ["HAIL_CONFIG_DIR": "/synthetic/hail"])
        #expect(store.file.path == "/synthetic/hail/privacy/state.json")
    }

    // MARK: Startup and restart

    @Test(arguments: ["missing", "corrupt", "unreadable", "private"])
    func startupReadsTheFileBeforeAnyStream(_ planted: String) async throws {
        let store = Self.store()
        switch planted {
        case "corrupt": try Self.plant("not json", in: store)
        case "unreadable": try Self.plant("{\"private\":true,\"since\":1}", in: store, mode: 0o000)
        case "private": try Self.plant("{\"private\":true,\"since\":1}", in: store)
        default: break
        }
        let rig = try await DuckRig(script: Self.quiet, capabilities: [DuckMode.capability], privacy: store)
        defer { rig.close() }
        let reading = planted == "missing" ? "public" : planted
        #expect(rig.details("ambient_privacy_state").first == "startup=\(reading) private=\(planted != "missing")")
        #expect(await eventually { rig.connection() != nil && !Self.launches(rig).isEmpty })
        let connection = try #require(rig.connection())
        let startsPrivate = planted != "missing"
        #expect(Self.launches(rig).first?.hasSuffix("--start-private") == startsPrivate)
        #expect(rig.env.router.duckMode(connection: connection) == startsPrivate)
        if startsPrivate {
            #expect(await eventually { rig.details("ambient_duck_device") == ["on=true device=sent"] })
            #expect(rig.details("ambient_privacy_state").contains("restored=true"))
            #expect(rig.details("ambient_privacy_start").isEmpty)
        }
        await rig.finish()
    }

    /// Entering writes the file before `setDuck` returns, so before the clip or the device notice; a crash then
    /// (no exit ever confirmed) and a restart come back private, with the new child launched start-private.
    @Test func aRestartWhilePrivateComesBackPrivate() async throws {
        let store = Self.store()
        let first = try await DuckRig(script: Self.entering, capabilities: [DuckMode.capability], privacy: store)
        #expect(await eventually { first.details("ambient_duck").count == 1 })
        #expect(store.read() == .private)
        let body = try String(contentsOf: store.file, encoding: .utf8)
        #expect(!body.lowercased().contains("stop") && !body.contains("Rightyo") && !body.contains("recording"))
        // The process "dies": its connection ends without any exit. The file is never a way out, nor is the end.
        first.close()
        await first.env.router.settle()
        await first.env.listener.stop(reason: "synthetic crash")
        #expect(store.read() == .private)

        let second = try await DuckRig(script: Self.quiet, capabilities: [DuckMode.capability], privacy: store)
        defer { second.close() }
        #expect(second.details("ambient_privacy_state").first == "startup=private private=true")
        #expect(await eventually { !Self.launches(second).isEmpty })
        #expect(Self.launches(second).first?.hasSuffix("--control-fd 3 --start-private") == true)
        let connection = try #require(second.connection())
        #expect(second.env.router.duckMode(connection: connection))
        #expect(await eventually { second.details("ambient_duck_device") == ["on=true device=sent"] })
        await second.finish()
        #expect(store.read() == .private)
    }

    /// A child launched start-private after a restart that does not confirm it is killed; the file stays.
    @Test func anUnconfirmingChildAfterARestartIsRefused() async throws {
        let store = Self.store()
        try Self.plant("{\"private\":true,\"since\":1}", in: store)
        let script = AmbientDuckReloadTests.silent(advertises: true, version: 1)
        let rig = try await DuckRig(script: script, privacy: store)
        defer { rig.close() }
        #expect(await eventually { rig.details("ambient_privacy_start") == ["outcome=refused reason=unconfirmed"] })
        await rig.finish()
        #expect(store.read() == .private)
    }

    // MARK: The way out

    /// Only a confirmed exit clears the file, after the device was told; a connection's end never does.
    @Test func theExitClearsTheFileOnlyAfterItIsConfirmed() async throws {
        let store = Self.store()
        let rig = try await DuckRig(script: Self.entering, capabilities: [DuckMode.capability], privacy: store)
        defer { rig.close() }
        #expect(await eventually { rig.details("ambient_duck").count == 1 })
        let connection = try #require(rig.connection())
        #expect(store.read() == .private)
        #expect(rig.env.router.setDuck(false, connection: connection, reason: "voice") == 1)
        #expect(await eventually { store.read() == .public })
        let order = rig.ordered(["ambient_duck_device", "ambient_privacy_state"])
        let off = try #require(order.firstIndex(of: "ambient_duck_device on=false device=sent"))
        let cleared = try #require(order.firstIndex(of: "ambient_privacy_state clear=cleared"))
        #expect(off < cleared)
        // After the exit a new entry writes it again, and the connection's end leaves it.
        #expect(rig.env.router.setDuck(true, connection: connection, reason: "voice") == 1)
        #expect(store.read() == .private)
        rig.socket.cancel(with: .normalClosure, reason: nil)
        #expect(await eventually { !rig.env.router.duckMode(connection: connection) })
        await rig.env.router.settle()
        await rig.env.listener.stop(reason: "synthetic test complete")
        #expect(store.read() == .private)
    }
}
#endif
