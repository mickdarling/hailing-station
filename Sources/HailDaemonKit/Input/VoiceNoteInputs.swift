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
    /// What `mkdir` is asked for. Tests narrow it, as a umask would, to show a new folder still ends `0700` (#804).
    let requestedMode: mode_t
    /// Runs as each sweep starts. Tests hold it to show startup never waits for a sweep (#804).
    let beforeSweep: @Sendable () -> Void

    init(base: URL = FileManager.default.temporaryDirectory, requestedMode: mode_t = 0o700,
         beforeSweep: @escaping @Sendable () -> Void = {}) {
        folder = base.appendingPathComponent(Self.folderName, isDirectory: true)
        (self.requestedMode, self.beforeSweep) = (requestedMode, beforeSweep)
    }

    static func == (lhs: Self, rhs: Self) -> Bool { lhs.folder == rhs.folder }

    /// Why no input was made, as its log token (#804): the folder could not be made, or it is not the owner's own
    /// `0700` directory. A bad folder fails every note, so it is named apart from a failed write.
    enum Refusal: String, Error, Equatable {
        case folderFailed = "notes_folder_failed", folderUnsafe = "notes_folder_unsafe"
    }

    /// A fresh input path in `folder`, made when absent; refused unless the folder is the owner's directory, never a
    /// symlink, at exactly `0700`. A folder already there in any other mode is refused, never changed.
    func newInput() -> Result<URL, Refusal> {
        if !Self.makeFolder(folder.path, requested: requestedMode), errno != EEXIST { return .failure(.folderFailed) }
        guard isPrivate else { return .failure(.folderUnsafe) }
        return .success(folder.appendingPathComponent("hail-note-\(UUID().uuidString).txt"))
    }

    /// Makes the folder, then sets it to `0700` (#804): a umask narrows `mkdir`'s `requested` mode (0277 leaves
    /// `0500`, which no input can be written into). Only a folder this call made is set; `lchmod` never follows a
    /// symlink swapped in since, which `isPrivate` then refuses. False, with `errno` set, when nothing was made.
    static func makeFolder(_ path: String, requested: mode_t = 0o700) -> Bool {
        guard mkdir(path, requested) == 0 else { return false }
        _ = lchmod(path, 0o700)
        return true
    }

    private var isPrivate: Bool {
        var info = stat()
        return lstat(folder.path, &info) == 0 && info.st_mode & S_IFMT == S_IFDIR && info.st_uid == getuid()
            && info.st_mode & 0o7777 == 0o700
    }

    /// Removes this folder's note inputs older than `maxAge`. Lists `folder` only; an absent or unsafe one is left.
    func sweep(now: Date = Date()) {
        beforeSweep()
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
