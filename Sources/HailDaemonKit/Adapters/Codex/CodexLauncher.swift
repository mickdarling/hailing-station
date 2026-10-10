#if os(macOS)
import Foundation
import Security

/// Fixed public-safe refusals: no path, signature detail or child output is echoed.
enum CodexLaunchError: Error, Sendable, Equatable {
    case invalidPath, notExecutable, unsafeOwnership, signatureRejected, versionUnavailable, unsupportedVersion
    case binaryChanged
}

/// Identity of the exact file that was checked, so a later swap at the same path is refused.
private struct CodexFileIdentity: Sendable, Equatable {
    let device: Int32
    let inode: UInt64
    let size: Int64
    let modified: timespec
    let changed: timespec // ctime: unlike mtime, the owner cannot set it back.
    static func == (lhs: Self, rhs: Self) -> Bool {
        lhs.device == rhs.device && lhs.inode == rhs.inode && lhs.size == rhs.size
            && lhs.modified.tv_sec == rhs.modified.tv_sec && lhs.modified.tv_nsec == rhs.modified.tv_nsec
            && lhs.changed.tv_sec == rhs.changed.tv_sec && lhs.changed.tv_nsec == rhs.changed.tv_nsec
    }
}

/// Evidence about one resolved Codex binary. Only `CodexLauncher.verify` creates it.
struct CodexLaunchEvidence: Sendable {
    let executable: String
    let version: String
    fileprivate let identity: CodexFileIdentity

    /// The owned App Server argv for this exact binary. Environment and configuration isolation are the caller's.
    func appServerCommand(environment: [String]) throws -> OwnedStdioCommand {
        guard try CodexLauncher.inspect(executable).identity == identity else { throw CodexLaunchError.binaryChanged }
        return OwnedStdioCommand(executable: executable, arguments: ["app-server", "--listen", "stdio://"],
                                 environment: environment)
    }
}

/// Checks a configured Codex binary before anything launches it. No PATH lookup, shell wrapper or account access.
enum CodexLauncher {
    /// OpenAI's Developer ID designated requirement for the CLI bundled in ChatGPT.app. The two OIDs mark a
    /// Developer ID intermediate and a Developer ID Application leaf, so team development certificates fail.
    static let defaultRequirement = #"identifier "codex" and anchor apple generic"#
        + #" and certificate 1[field.1.2.840.113635.100.6.2.6] exists"#
        + #" and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"#
        + #" and certificate leaf[subject.OU] = "2DC432GLL2""#

    static func verify(
        path: String, requirement: String = defaultRequirement,
        probe: @Sendable (String) async throws -> Data = { try await readVersion($0) }
    ) async throws -> CodexLaunchEvidence {
        let (resolved, identity) = try inspect(path)
        try checkSignature(resolved, requirement: requirement)
        let version = try parseVersion(try await probe(resolved))
        guard CodexAppServerProtocol.supportedVersions.contains(version) else {
            throw CodexLaunchError.unsupportedVersion
        }
        guard try inspect(resolved).identity == identity else { throw CodexLaunchError.binaryChanged }
        return CodexLaunchEvidence(executable: resolved, version: version, identity: identity)
    }

    /// Exactly `codex-cli <version>` and one newline; anything else is refused.
    static func parseVersion(_ output: Data) throws -> String {
        guard let text = String(data: output, encoding: .utf8), text.hasPrefix("codex-cli "), text.hasSuffix("\n")
        else { throw CodexLaunchError.versionUnavailable }
        let version = text.dropFirst("codex-cli ".count).dropLast()
        let allowed = CharacterSet(charactersIn: "0123456789.-abcdefghijklmnopqrstuvwxyz")
        guard (1...40).contains(version.count), version.unicodeScalars.allSatisfy(allowed.contains) else {
            throw CodexLaunchError.versionUnavailable
        }
        return String(version)
    }

    /// Runs `<binary> --version` with an empty environment through the owned child; reaped on every exit.
    static func readVersion(_ path: String, deadline: Duration = .seconds(5), limit: Int = 256) async throws -> Data {
        let child: OwnedStdioChild
        do {
            child = try OwnedStdioChild(command: OwnedStdioCommand(executable: path, arguments: ["--version"]))
        } catch { throw CodexLaunchError.versionUnavailable }
        do {
            let output = try await withThrowingTaskGroup(of: Data?.self) { group in
                group.addTask {
                    var output = Data()
                    for try await chunk in child.chunks {
                        output.append(chunk)
                        guard output.count <= limit else { throw CodexLaunchError.versionUnavailable }
                    }
                    return output
                }
                group.addTask { try await Task.sleep(for: deadline); child.cancel(); return nil }
                defer { group.cancelAll() }
                guard let first = try await group.next(), let output = first else {
                    throw CodexLaunchError.versionUnavailable
                }
                return output
            }
            child.cancel(); await child.join()
            try Task.checkCancellation()
            return output
        } catch {
            child.cancel(); await child.join()
            throw CodexLaunchError.versionUnavailable
        }
    }

    /// Absolute path, symlinks resolved, regular executable Mach-O owned by root or this user and
    /// writable by nobody else, inside a folder with the same ownership rule.
    fileprivate static func inspect(_ path: String) throws -> (path: String, identity: CodexFileIdentity) {
        guard path.hasPrefix("/"), !path.contains("\0"), let real = realpath(path, nil) else {
            throw CodexLaunchError.invalidPath
        }
        let resolved = String(cString: real); free(real)
        let descriptor = open(resolved, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { throw CodexLaunchError.invalidPath }
        defer { close(descriptor) }
        var file = stat(), folder = stat()
        guard fstat(descriptor, &file) == 0, stat((resolved as NSString).deletingLastPathComponent, &folder) == 0
        else { throw CodexLaunchError.invalidPath }
        guard file.st_mode & S_IFMT == S_IFREG, file.st_mode & S_IXUSR != 0, isMachO(descriptor) else {
            throw CodexLaunchError.notExecutable
        }
        guard safelyOwned(file), safelyOwned(folder), !hasExtendedACL(descriptor: descriptor),
              !hasExtendedACL(folder: (resolved as NSString).deletingLastPathComponent) else {
            throw CodexLaunchError.unsafeOwnership
        }
        return (resolved, CodexFileIdentity(device: file.st_dev, inode: file.st_ino, size: file.st_size,
                                            modified: file.st_mtimespec, changed: file.st_ctimespec))
    }

    private static func safelyOwned(_ info: stat) -> Bool {
        (info.st_uid == 0 || info.st_uid == geteuid()) && info.st_mode & (S_IWGRP | S_IWOTH) == 0
    }

    /// Any extended ACL could grant another user write or delete beyond the mode bits, so none is accepted.
    private static func hasExtendedACL(descriptor: Int32) -> Bool {
        guard let acl = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else { return errno != ENOENT }
        acl_free(UnsafeMutableRawPointer(acl)); return true
    }
    private static func hasExtendedACL(folder: String) -> Bool {
        guard let acl = acl_get_link_np(folder, ACL_TYPE_EXTENDED) else { return errno != ENOENT }
        acl_free(UnsafeMutableRawPointer(acl)); return true
    }

    /// Thin 64-bit or universal Mach-O only, so a shell or interpreter wrapper is refused.
    private static func isMachO(_ descriptor: Int32) -> Bool {
        var magic = [UInt8](repeating: 0, count: 4)
        guard pread(descriptor, &magic, 4, 0) == 4 else { return false }
        return [[0xCF, 0xFA, 0xED, 0xFE], [0xCA, 0xFE, 0xBA, 0xBE], [0xCA, 0xFE, 0xBA, 0xBF]].contains(magic)
    }

    private static func checkSignature(_ path: String, requirement: String) throws {
        var code: SecStaticCode?, required: SecRequirement?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess,
              SecRequirementCreateWithString(requirement as CFString, [], &required) == errSecSuccess,
              let code, let required else { throw CodexLaunchError.signatureRejected }
        let flags = SecCSFlags(rawValue: kSecCSStrictValidate | kSecCSCheckAllArchitectures)
        guard SecStaticCodeCheckValidity(code, flags, required) == errSecSuccess else {
            throw CodexLaunchError.signatureRejected
        }
    }
}
#endif
