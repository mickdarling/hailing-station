import Darwin
import Foundation
import Security

/// The app allowed to drive `haild coaching --parent-control` (#645). The owner records it with
/// `haild coaching trust-app <path-to-app>`. An ad-hoc build is pinned by bundle identifier plus cdhash, so every
/// rebuild needs a fresh trust-app. A team-signed build is pinned by team and identifier, and must also run with
/// the hardened runtime and without `get-task-allow`.
struct CoachingTrustedApp: Codable, Equatable {
    let identifier: String
    let cdhash: String?
    let teamID: String?

    static let fileName = "coaching-trusted-app.json"

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

/// Every refusal is `localControlRequired`, raised before any coaching configuration is parsed.
enum CoachingParentTrust {
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

    /// The control socket's peer is the process that created the socketpair. Its audit token is fixed then, so a
    /// reused PID cannot stand in for it. A pipe, FIFO or terminal has no peer token and is refused.
    static func verifyPeer(of descriptor: Int32, pinFile: URL = pinFile()) throws {
        var details = stat()
        guard fstat(descriptor, &details) == 0, details.st_mode & S_IFMT == S_IFSOCK else { throw refused }
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0,
              length == socklen_t(MemoryLayout<audit_token_t>.size) else { throw refused }
        let pin = try loadPin(pinFile)
        guard let text = pin.requirement else { throw refused }
        var requirement: SecRequirement?, code: SecCode?
        let audit = withUnsafeBytes(of: &token) { Data($0) }
        guard SecRequirementCreateWithString(text as CFString, [], &requirement) == errSecSuccess,
              let requirement,
              SecCodeCopyGuestWithAttributes(nil, [kSecGuestAttributeAudit: audit] as CFDictionary, [],
                                             &code) == errSecSuccess, let code,
              SecCodeCheckValidity(code, [], requirement) == errSecSuccess else { throw refused }
        if pin.teamID != nil {
            guard let information = signing(code), hardened(information) else { throw refused }
        }
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
              CoachingConfiguration.hasNoExtendedACL(fd) else { throw refused }
        var buffer = [UInt8](repeating: 0, count: 1_025)
        let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        guard count > 0, count <= 1_024,
              let pin = try? JSONDecoder().decode(CoachingTrustedApp.self, from: Data(buffer.prefix(count))),
              pin.requirement != nil else { throw refused }
        return pin
    }

    /// Reads the app's own signature. An ad-hoc signature becomes a cdhash pin; a team signature must already
    /// carry the hardened runtime and no `get-task-allow`.
    static func pin(for code: SecStaticCode) throws -> CoachingTrustedApp {
        guard SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess, let information = signing(code),
              let identifier = information[kSecCodeInfoIdentifier as String] as? String,
              let unique = information[kSecCodeInfoUnique as String] as? Data else { throw refused }
        let pin: CoachingTrustedApp
        if let team = information[kSecCodeInfoTeamIdentifier as String] as? String {
            guard hardened(information) else { throw refused }
            pin = CoachingTrustedApp(identifier: identifier, cdhash: nil, teamID: team)
        } else {
            pin = CoachingTrustedApp(identifier: identifier,
                                     cdhash: unique.map { String(format: "%02x", $0) }.joined(), teamID: nil)
        }
        guard pin.requirement != nil else { throw refused }
        return pin
    }

    /// `haild coaching trust-app <path>`: owner-run from a terminal only. Writes 0600 in the 0700 config directory.
    static func trustApp(_ arguments: [String], pinFile: URL = pinFile()) throws {
        guard isatty(STDIN_FILENO) == 1, arguments.count == 1, let path = arguments.first, path.hasPrefix("/") else {
            throw refused
        }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(fileURLWithPath: path) as CFURL, [], &code) == errSecSuccess,
              let code else { throw refused }
        try write(try pin(for: code), to: pinFile)
        FileHandle.standardError.write(Data("haild: trusted the app for private coaching\n".utf8))
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

    private static var refused: CoachingCommandError { .localControlRequired }

    private static func signing(_ code: SecStaticCode) -> [String: Any]? {
        var information: CFDictionary?
        let flags = SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSRequirementInformation)
        guard SecCodeCopySigningInformation(code, flags, &information) == errSecSuccess else { return nil }
        return information as? [String: Any]
    }

    private static func signing(_ code: SecCode) -> [String: Any]? {
        var staticCode: SecStaticCode?
        guard SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode else { return nil }
        return signing(staticCode)
    }

    private static func hardened(_ information: [String: Any]) -> Bool {
        guard let flags = information[kSecCodeInfoFlags as String] as? UInt32 else { return false }
        let entitlements = information[kSecCodeInfoEntitlementsDict as String] as? [String: Any] ?? [:]
        return flags & SecCodeSignatureFlags.runtime.rawValue != 0
            && entitlements["com.apple.security.get-task-allow"] as? Bool != true
    }
}
