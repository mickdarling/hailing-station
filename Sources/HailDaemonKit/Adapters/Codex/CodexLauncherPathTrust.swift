#if os(macOS)
import Foundation

/// Path trust for the Codex binary: ownership, mode bits and ACLs on the file, its folder and every ancestor.
extension CodexLauncher {
    /// Every folder up to `/` must be owned by root or this user, not world-writable, and carry no ACL entry that
    /// lets anyone add, delete or re-permission entries. Group write is accepted only for root-owned wheel/admin
    /// folders such as `/Applications`: those members can already become root.
    static func ancestorsAreTrusted(_ folder: String) throws -> Bool {
        var path = folder
        while true {
            var info = stat()
            guard lstat(path, &info) == 0, info.st_mode & S_IFMT == S_IFDIR else { throw CodexLaunchError.invalidPath }
            let groupWriteTrusted = info.st_uid == 0 && (info.st_gid == 0 || info.st_gid == 80)
            guard info.st_uid == 0 || info.st_uid == geteuid(), info.st_mode & S_IWOTH == 0,
                  info.st_mode & S_IWGRP == 0 || groupWriteTrusted, !aclAllowsChanges(folder: path) else {
                return false
            }
            if path == "/" { return true }
            path = (path as NSString).deletingLastPathComponent
        }
    }

    static func safelyOwned(_ info: stat) -> Bool {
        (info.st_uid == 0 || info.st_uid == geteuid()) && info.st_mode & (S_IWGRP | S_IWOTH) == 0
    }

    /// The binary and its own folder accept no extended ACL at all.
    static func hasExtendedACL(descriptor: Int32) -> Bool {
        guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else { return errno != ENOENT }
        acl_free(UnsafeMutableRawPointer(acl)); return true
    }
    static func hasExtendedACL(folder: String) -> Bool {
        guard let acl = acl_get_link_np(folder, ACL_TYPE_EXTENDED) else { return errno != ENOENT }
        acl_free(UnsafeMutableRawPointer(acl)); return true
    }

    /// Ancestors may carry deny entries (a home folder has one by default) but no allow entry granting changes.
    /// An unreadable ACL fails closed.
    static func aclAllowsChanges(folder: String) -> Bool {
        guard let acl = acl_get_link_np(folder, ACL_TYPE_EXTENDED) else { return errno != ENOENT }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        let changes: [acl_perm_t] = [ACL_ADD_FILE, ACL_ADD_SUBDIRECTORY, ACL_DELETE_CHILD, ACL_DELETE,
                                     ACL_WRITE_SECURITY, ACL_CHANGE_OWNER, ACL_WRITE_EXTATTRIBUTES]
        var entry: acl_entry_t?
        var which = ACL_FIRST_ENTRY.rawValue
        while acl_get_entry(acl, Int32(which), &entry) == 0 {
            which = ACL_NEXT_ENTRY.rawValue
            var tag = ACL_UNDEFINED_TAG, permissions: acl_permset_t?
            guard let entry, acl_get_tag_type(entry, &tag) == 0, acl_get_permset(entry, &permissions) == 0,
                  let permissions else { return true }
            if tag == ACL_EXTENDED_ALLOW, changes.contains(where: { acl_get_perm_np(permissions, $0) != 0 }) {
                return true
            }
        }
        return false
    }
}
#endif
