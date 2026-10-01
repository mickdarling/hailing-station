#if os(macOS)
import Darwin
import Foundation

/// An owner-only leaf of trusted local configuration, never a caller-supplied deletion target.
/// Removal is authorized only by the group owner after its pinned quiescence proof.
final class OwnedReplyJobDirectory: Sendable {
    let url: URL
    private let parent: Int32
    private let root: URL
    private let rootIdentity: stat
    private let identity: stat?
    var usable: Bool { identity != nil }

    init(root: URL) throws {
        do { try OwnedReplyRenderer.validateOutputRoot(root) } catch {
            throw OwnedReplyPublisherError.invalidConfiguration
        }
        guard let descriptor = try PolicyFile(directory: root).openDirectory() else {
            throw OwnedReplyPublisherError.invalidConfiguration
        }
        var keep = false
        defer { if !keep { close(descriptor) } }
        var information = stat(), path = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fstat(descriptor, &information) == 0, fcntl(descriptor, F_GETPATH, &path) == 0,
              information.st_uid == getuid(), information.st_mode & 0o777 == 0o700,
              Self.noACL(descriptor),
              let canonical = String(bytes: path.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) },
                                     encoding: .utf8) else {
            throw OwnedReplyPublisherError.invalidConfiguration
        }
        self.root = URL(fileURLWithPath: canonical, isDirectory: true)
        rootIdentity = information
        let name = "hailing-reply-job-\(UUID().uuidString)"
        url = self.root.appendingPathComponent(name, isDirectory: true)
        guard mkdirat(descriptor, name, 0o700) == 0 else { throw OwnedReplyPublisherError.startupFailed }
        var child = stat()
        let known = fstatat(descriptor, name, &child, AT_SYMLINK_NOFOLLOW) == 0 &&
            child.st_mode & S_IFMT == S_IFDIR && child.st_uid == getuid() && child.st_mode & 0o777 == 0o700
        identity = known ? child : nil
        parent = descriptor; keep = true
    }

    deinit { close(parent) }

    func remove() -> Bool {
        guard let identity, let currentRoot = try? PolicyFile.info(root), same(currentRoot, rootIdentity),
              let current = try? PolicyFile.info(url), same(current, identity) else { return false }
        let descriptor = openat(parent, url.lastPathComponent, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var information = stat()
        var remaining = 4_096
        guard fstat(descriptor, &information) == 0, same(information, identity),
              information.st_uid == getuid(), information.st_mode & 0o777 == 0o700,
              Self.removeContents(descriptor, depth: 0, remaining: &remaining),
              fstatat(parent, url.lastPathComponent, &information, AT_SYMLINK_NOFOLLOW) == 0,
              same(information, identity) else { return false }
        // No inode-conditional rmdir exists: hostile concurrent same-UID name rebinding is excluded.
        return unlinkat(parent, url.lastPathComponent, AT_REMOVEDIR) == 0
    }

    private func same(_ lhs: stat, _ rhs: stat) -> Bool {
        lhs.st_dev == rhs.st_dev && lhs.st_ino == rhs.st_ino && lhs.st_mode & S_IFMT == S_IFDIR
    }

    private static func noACL(_ descriptor: Int32) -> Bool {
        guard let access = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else { return errno == ENOENT }
        defer { acl_free(UnsafeMutableRawPointer(access)) }
        var entry: acl_entry_t?
        return acl_get_entry(access, Int32(ACL_FIRST_ENTRY.rawValue), &entry) == -1 && errno == EINVAL
    }

    private static func removeContents(_ descriptor: Int32, depth: Int, remaining: inout Int) -> Bool {
        guard depth < 8, let names = names(descriptor) else { return false }
        for name in names {
            guard remaining > 0 else { return false }
            remaining -= 1
            var information = stat()
            guard fstatat(descriptor, name, &information, AT_SYMLINK_NOFOLLOW) == 0 else { return false }
            if information.st_mode & S_IFMT == S_IFDIR {
                let child = openat(descriptor, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard child >= 0 else { return false }
                var opened = stat()
                let valid = fstat(child, &opened) == 0 && opened.st_dev == information.st_dev &&
                    opened.st_ino == information.st_ino &&
                    removeContents(child, depth: depth + 1, remaining: &remaining)
                close(child)
                guard valid, fstatat(descriptor, name, &opened, AT_SYMLINK_NOFOLLOW) == 0,
                      opened.st_dev == information.st_dev, opened.st_ino == information.st_ino,
                      unlinkat(descriptor, name, AT_REMOVEDIR) == 0 else { return false }
            } else if unlinkat(descriptor, name, 0) != 0 { return false }
        }
        return true
    }

    private static func names(_ descriptor: Int32) -> [String]? {
        let copy = dup(descriptor)
        guard copy >= 0 else { return nil }
        guard let directory = fdopendir(copy) else { close(copy); return nil }
        defer { closedir(directory) }
        var result: [String] = []
        while true {
            errno = 0
            guard let entry = readdir(directory) else { return errno == 0 ? result : nil }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
            }
            if name != ".", name != ".." { result.append(name) }
            guard result.count <= 1_024 else { return nil }
        }
    }
}
#endif
