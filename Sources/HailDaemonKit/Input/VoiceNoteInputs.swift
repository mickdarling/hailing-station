import Darwin
import Foundation

/// Where a Shortcut's note input (#552) is written: an owner-only `hail-notes/` folder in the per-user temporary
/// folder, so the sweep of inputs left by a haild that exited mid-Shortcut lists haild's own folder and nothing else.
/// The temporary folder itself is shared with everything the user runs and can hold hundreds of thousands of entries;
/// listing it at startup held `listener_ready` past the deploy's readiness deadline. Inputs an older haild left at the
/// top level are harmless and no longer swept.
struct VoiceNoteInputs: Sendable, Equatable {
    static let folderName = "hail-notes"
    /// Older than any run could still be reading: a Shortcut is stopped at 30 s.
    static let maxAge: TimeInterval = 300
    let folder: URL

    init(base: URL = FileManager.default.temporaryDirectory) {
        folder = base.appendingPathComponent(Self.folderName, isDirectory: true)
    }

    /// A fresh input path in `folder`, created `0700` when absent; nil unless it is the owner's private directory
    /// (never a symlink, never readable by anyone else).
    func newInput() -> URL? {
        if mkdir(folder.path, 0o700) != 0, errno != EEXIST { return nil }
        guard isPrivate else { return nil }
        return folder.appendingPathComponent("hail-note-\(UUID().uuidString).txt")
    }

    private var isPrivate: Bool {
        var info = stat()
        return lstat(folder.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR && info.st_uid == getuid()
            && info.st_mode & 0o077 == 0
    }

    /// Removes this folder's note inputs older than `maxAge`. Lists `folder` only; an absent or unsafe one is left.
    func sweep(now: Date = Date()) {
        guard isPrivate else { return }
        let files = FileManager.default
        for name in (try? files.contentsOfDirectory(atPath: folder.path)) ?? []
        where name.hasPrefix("hail-note-") && name.hasSuffix(".txt") {
            let path = folder.appendingPathComponent(name).path
            let modified = (try? files.attributesOfItem(atPath: path))?[.modificationDate] as? Date
            guard let modified, modified < now.addingTimeInterval(-Self.maxAge) else { continue }
            try? files.removeItem(atPath: path)
        }
    }

    /// Runs `work` off the caller's path and returns at once, so no folder can hold startup.
    @discardableResult
    static func inBackground(_ work: @escaping @Sendable () -> Void) -> Task<Void, Never> {
        Task.detached(priority: .utility) { work() }
    }
}
