import Foundation

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
            guard candidate.path != "/" else { return }
            candidate = candidate.deletingLastPathComponent()
        }
    }
}
