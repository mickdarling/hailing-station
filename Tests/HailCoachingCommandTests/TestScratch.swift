import Foundation
import Synchronization

/// Scratch folders for tests (#800): in the per-user temp dir as before, and removed when the test process exits, so
/// helpers that never clean up no longer pile them up there (haild's startup lists that folder). A process killed
/// before it exits still leaves its own. One copy per test target, as the targets share no support module.
enum TestScratch {
    private static let paths = Mutex<[String]>([])
    private static let cleanup: Void = { atexit { TestScratch.removeAll() } }()

    /// A not-yet-created `<prefix>-<UUID>` in the temp dir, removed at exit with everything in it.
    static func url(_ prefix: String) -> URL {
        register(FileManager.default.temporaryDirectory.appendingPathComponent("\(prefix)-\(UUID())"))
    }

    /// Removes `url` at exit, once, however many times it is registered (a folder a whole process shares).
    @discardableResult
    static func register(_ url: URL) -> URL {
        _ = cleanup
        paths.withLock { if !$0.contains(url.path) { $0.append(url.path) } }
        return url
    }

    private static func removeAll() {
        for path in paths.withLock({ $0 }) { try? FileManager.default.removeItem(atPath: path) }
    }
}
