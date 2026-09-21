import Foundation
import Darwin

extension LocalReplyEndpoint {
    static func resolvedDirectory(_ directory: URL) throws -> URL {
        guard let resolved = realpath(directory.path, nil) else {
            throw LocalReplyEndpointError.failed("socket directory could not be resolved")
        }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }

    /// Network.framework binds Unix sockets by path, not relative to an open directory descriptor.
    /// Refuse an ancestry another local user can rename while the listener starts, so the directory
    /// checked above remains the directory in which the socket is created and later removed.
    static func checkSocketAncestors(_ directory: URL) throws {
        var candidate = directory
        while true {
            var info = stat()
            guard stat(candidate.path, &info) == 0,
                  info.st_mode & S_IFMT == S_IFDIR,
                  info.st_uid == 0 || info.st_uid == getuid(),
                  info.st_mode & 0o022 == 0 else {
                throw LocalReplyEndpointError.failed(
                    "socket path has an unsafe ancestor: \(candidate.path)"
                )
            }
            try checkNoWritableACL(candidate)
            guard candidate.path != "/" else { return }
            candidate = candidate.deletingLastPathComponent()
        }
    }

    private static func checkNoWritableACL(_ directory: URL) throws {
        guard let acl = acl_get_file(directory.path, ACL_TYPE_EXTENDED) else {
            if errno == ENOENT { return }
            throw LocalReplyEndpointError.failed("socket ancestor ACL could not be checked")
        }
        defer { acl_free(UnsafeMutableRawPointer(acl)) }
        var entry: acl_entry_t?
        var position = Int32(ACL_FIRST_ENTRY.rawValue)
        while acl_get_entry(acl, position, &entry) == 0, let entry {
            var tag = ACL_UNDEFINED_TAG
            var permissions: acl_permset_t?
            guard acl_get_tag_type(entry, &tag) == 0,
                  acl_get_permset(entry, &permissions) == 0,
                  let permissions else {
                throw LocalReplyEndpointError.failed("socket ancestor ACL could not be checked")
            }
            if tag == ACL_EXTENDED_ALLOW, writableACLPermissions.contains(where: {
                acl_get_perm_np(permissions, $0) == 1
            }) {
                throw LocalReplyEndpointError.failed(
                    "socket path has a writable ACL ancestor: \(directory.path)"
                )
            }
            position = Int32(ACL_NEXT_ENTRY.rawValue)
        }
    }

    private static let writableACLPermissions: [acl_perm_t] = [
        ACL_ADD_FILE, ACL_ADD_SUBDIRECTORY, ACL_DELETE, ACL_DELETE_CHILD,
        ACL_WRITE_ATTRIBUTES, ACL_WRITE_EXTATTRIBUTES, ACL_WRITE_SECURITY, ACL_CHANGE_OWNER
    ]
}
