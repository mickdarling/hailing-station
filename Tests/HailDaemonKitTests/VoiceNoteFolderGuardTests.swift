#if os(macOS)
import Darwin
import Foundation
import Testing
@testable import HailDaemonKit

/// The `hail-notes/` folder is used and swept only when it is this user's own directory, never a symlink, and closed
/// to everyone else (#804). Each case here fails one check alone, so none of the checks can regress unnoticed: a
/// symlink to a private `0700` folder (`lstat`, not `stat`), the same symlink `lchmod`-ed to `0700` and a `0600` file
/// of that name (the directory check), and folders open to others for reading or only for searching (the mode check).
/// Synthetic files only.
@Suite(.serialized, .timeLimit(.minutes(1)), .frozenGuardBudget) struct VoiceNoteFolderGuardTests {
    private struct Case {
        let base: URL, inputs: VoiceNoteInputs, decoy: URL
    }

    /// A base holding a stale note input `decoy` the sweep must leave, wherever `make` points `hail-notes`.
    private static func setUp(_ make: (_ notes: URL, _ elsewhere: URL) throws -> URL) throws -> Case {
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("notes-guard-\(UUID().uuidString)")
        let elsewhere = base.appendingPathComponent("elsewhere")
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let inputs = VoiceNoteInputs(base: base)
        let decoyFolder = try make(inputs.folder, elsewhere)
        let decoy = decoyFolder.appendingPathComponent("hail-note-decoy.txt")
        try Data("synthetic".utf8).write(to: decoy)
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -3600)],
                                              ofItemAtPath: decoy.path)
        return Case(base: base, inputs: inputs, decoy: decoy)
    }

    private static func expectRefused(_ guarded: Case) {
        #expect(guarded.inputs.newInput() == nil)
        guarded.inputs.sweep()
        #expect(FileManager.default.fileExists(atPath: guarded.decoy.path), "the sweep removed a note it must not")
    }

    @Test func aSymlinkToAPrivateFolderIsRefused() throws {
        let guarded = try Self.setUp { notes, elsewhere in
            try FileManager.default.createSymbolicLink(at: notes, withDestinationURL: elsewhere)
            return elsewhere
        }
        defer { try? FileManager.default.removeItem(at: guarded.base) }
        Self.expectRefused(guarded)
    }

    @Test func aSymlinkWhoseOwnModeIsPrivateIsRefused() throws {
        let guarded = try Self.setUp { notes, elsewhere in
            try FileManager.default.createSymbolicLink(at: notes, withDestinationURL: elsewhere)
            guard lchmod(notes.path, 0o700) == 0 else { throw POSIXError(.init(rawValue: errno) ?? .EPERM) }
            var info = stat()
            #expect(lstat(notes.path, &info) == 0 && info.st_mode & 0o777 == 0o700)
            return elsewhere
        }
        defer { try? FileManager.default.removeItem(at: guarded.base) }
        Self.expectRefused(guarded)
    }

    @Test func aPrivateFileOfThatNameIsRefused() throws {
        let guarded = try Self.setUp { notes, elsewhere in
            try Data().write(to: notes)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: notes.path)
            return elsewhere
        }
        defer { try? FileManager.default.removeItem(at: guarded.base) }
        #expect(guarded.inputs.newInput() == nil)
        let mode = try FileManager.default.attributesOfItem(atPath: guarded.inputs.folder.path)[.posixPermissions]
        #expect(mode as? Int == 0o600, "the file was changed")
    }

    @Test(arguments: [0o755, 0o711, 0o750, 0o701])
    func aFolderOthersCanEnterIsRefused(mode: Int) throws {
        let guarded = try Self.setUp { notes, _ in
            try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: false)
            try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: notes.path)
            return notes
        }
        defer { try? FileManager.default.removeItem(at: guarded.base) }
        Self.expectRefused(guarded)
    }

    /// The control: the same stale input in a private folder is swept, so the refusals above are not vacuous.
    @Test func aPrivateFolderIsUsedAndSwept() throws {
        let guarded = try Self.setUp { notes, _ in
            try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
            return notes
        }
        defer { try? FileManager.default.removeItem(at: guarded.base) }
        #expect(guarded.inputs.newInput() != nil)
        guarded.inputs.sweep()
        #expect(!FileManager.default.fileExists(atPath: guarded.decoy.path))
    }
}
#endif
