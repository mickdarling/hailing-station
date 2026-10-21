import Darwin
import Foundation

/// The app allowed to drive `haild coaching --parent-control` (#645). The owner records it with
/// `haild coaching trust-app <path-to-app>`. An ad-hoc build is pinned by bundle identifier plus cdhash, so every
/// rebuild needs a fresh trust-app. A team-signed build is pinned by team and identifier, and must also run with
/// the hardened runtime and without `get-task-allow`.
struct CoachingTrustedApp: Codable, Equatable {
    let identifier: String
    let cdhash: String?
    let teamID: String?

    static let fileName = "coaching-trusted-app.json"
    /// The only app `trust-app` will pin: the Mac station target's bundle identifier (project.yml, #266).
    static let hailBundleIdentifier = "com.mickdarling.Hail-macOS"

    /// Only plain characters reach the requirement language, so a pin cannot widen its own requirement.
    var requirement: String? {
        guard Self.plain(identifier, allowed: Self.identifierCharacters, length: 1...128) else { return nil }
        switch (cdhash, teamID) {
        case let (hash?, nil):
            guard [40, 64].contains(hash.count), Self.plain(hash, allowed: Self.hex, length: 40...64) else {
                return nil
            }
            return "identifier \"\(identifier)\" and cdhash H\"\(hash)\""
        case let (nil, team?):
            guard Self.plain(team, allowed: Self.teamCharacters, length: 10...10) else { return nil }
            return "anchor apple generic and certificate leaf[subject.OU] = \"\(team)\""
                + " and identifier \"\(identifier)\""
        default: return nil
        }
    }

    private static let identifierCharacters = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789.-")
    private static let teamCharacters = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
    private static let hex = Set("0123456789abcdef")
    private static func plain(_ value: String, allowed: Set<Character>, length: ClosedRange<Int>) -> Bool {
        length.contains(value.count) && value.allSatisfy(allowed.contains)
    }
}

/// The pin file: where it lives, how it is read and written, and how doctor and the card describe it.
extension CoachingParentTrust {
    /// Always the account's own `~/.config/hail`, from the password database. The environment is ignored: the
    /// spawner controls it, so `HAIL_CONFIG_DIR` or `HOME` must not be able to point haild at a pin it wrote.
    /// Tests inject another file only through the `pinFile:` parameters below.
    static func pinFile() -> URL {
        guard let entry = getpwuid(getuid()), let home = entry.pointee.pw_dir else {
            return URL(fileURLWithPath: "/nonexistent/\(CoachingTrustedApp.fileName)")
        }
        return URL(fileURLWithPath: String(cString: home), isDirectory: true)
            .appendingPathComponent(".config/hail", isDirectory: true)
            .appendingPathComponent(CoachingTrustedApp.fileName)
    }

    /// For `haild doctor` and the Mac card: which app is pinned, so a rewritten pin is noticeable.
    static func pinSummary(pinFile: URL = pinFile()) -> String {
        guard FileManager.default.fileExists(atPath: pinFile.path) else { return "none pinned" }
        guard let pin = try? loadPin(pinFile) else { return "pin file refused (not private or malformed)" }
        if let team = pin.teamID { return "\(pin.identifier), team \(team)" }
        return "\(pin.identifier), cdhash \(pin.cdhash.map { String($0.prefix(12)) } ?? "?")"
    }

    /// Same rules as the listener profile: no symlink or FIFO, a small regular file owned by this user, owner-only
    /// mode bits and no extended ACL. Errors never echo the path or contents.
    static func loadPin(_ url: URL) throws -> CoachingTrustedApp {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK)
        guard fd >= 0 else { throw refused }
        defer { close(fd) }
        var details = stat()
        guard fstat(fd, &details) == 0, details.st_mode & S_IFMT == S_IFREG, details.st_uid == getuid(),
              details.st_mode & 0o077 == 0, (1...1_024).contains(details.st_size),
              hasNoExtendedACL(fd) else { throw refused }
        var buffer = [UInt8](repeating: 0, count: 1_025)
        let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        guard count > 0, count <= 1_024,
              let pin = try? JSONDecoder().decode(CoachingTrustedApp.self, from: Data(buffer.prefix(count))),
              pin.requirement != nil else { throw refused }
        return pin
    }

    static func write(_ pin: CoachingTrustedApp, to url: URL) throws {
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        var details = stat()
        guard lstat(directory.path, &details) == 0, details.st_mode & S_IFMT == S_IFDIR,
              details.st_uid == getuid(), details.st_mode & 0o077 == 0 else { throw refused }
        let data = try JSONEncoder().encode(pin)
        let temporary = directory.appendingPathComponent(".\(CoachingTrustedApp.fileName).\(UUID().uuidString)")
        let fd = open(temporary.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw refused }
        let written = data.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
        close(fd)
        guard written == data.count, rename(temporary.path, url.path) == 0 else {
            unlink(temporary.path); throw refused
        }
    }

    /// The same descriptor check as the listener profile (`CoachingConfiguration`): mode bits alone do not establish
    /// owner privacy on macOS, so any extended entry or inspection failure is refused.
    static func hasNoExtendedACL(_ descriptor: Int32) -> Bool {
        guard let access = acl_get_fd_np(descriptor, ACL_TYPE_EXTENDED) else { return errno == ENOENT }
        defer { acl_free(UnsafeMutableRawPointer(access)) }
        var entry: acl_entry_t?
        return acl_get_entry(access, Int32(ACL_FIRST_ENTRY.rawValue), &entry) == -1 && errno == EINVAL
    }
}
