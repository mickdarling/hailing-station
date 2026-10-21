import Darwin
import Foundation
import HailDaemonKit
import Security

/// A gate refusal, distinct from a configuration refusal so callers and tests can tell them apart (exit 77).
/// The pinned app and its file live in CoachingParentTrust+Pin.swift.
enum CoachingParentRefusal: Error, Equatable { case unverified }

/// Every refusal is `CoachingParentRefusal.unverified`, raised before any coaching configuration is parsed.
enum CoachingParentTrust {
    /// The control socket must be an unnamed socketpair end whose peer is this process's parent, and that peer's
    /// audit token (fixed when the pair was made, so a reused PID cannot stand in) must satisfy the pin. A pipe,
    /// FIFO, terminal, or a connection to a named socket someone else listens on is refused. `parent` is a test seam.
    static func verifyPeer(of descriptor: Int32, pinFile: URL = pinFile(), parent: pid_t = getppid()) throws {
        var details = stat()
        guard fstat(descriptor, &details) == 0, details.st_mode & S_IFMT == S_IFSOCK,
              unnamed(descriptor, peer: false), unnamed(descriptor, peer: true) else { throw refused }
        var token = audit_token_t()
        var length = socklen_t(MemoryLayout<audit_token_t>.size)
        guard getsockopt(descriptor, SOL_LOCAL, LOCAL_PEERTOKEN, &token, &length) == 0,
              length == socklen_t(MemoryLayout<audit_token_t>.size),
              parent > 1, token.val.5 == UInt32(bitPattern: parent) else { throw refused } // val.5 is the pid.
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

    /// Reads the app's own signature. An ad-hoc signature becomes a cdhash pin; a team signature must already
    /// carry the hardened runtime and no `get-task-allow`.
    static func pin(for code: SecStaticCode) throws -> CoachingTrustedApp {
        guard SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess, let information = signing(code),
              let identifier = information[kSecCodeInfoIdentifier as String] as? String,
              let unique = information[kSecCodeInfoUnique as String] as? Data,
              // OS binaries (zsh, osascript, TextEdit) are never the coaching app.
              (information[kSecCodeInfoPlatformIdentifier as String] as? Int ?? 0) == 0 else { throw refused }
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

    /// `haild coaching trust-app <path>`: owner-run from a terminal only, and only for a signed Hailing Station
    /// `.app` (an ad-hoc "Sign to Run Locally" build is fine; a linker-signed-only build is refused). Writes 0600 in
    /// the 0700 config directory, then records `coaching_app_pinned` in the audit log when it is free.
    static func trustApp(_ arguments: [String], pinFile: URL = pinFile()) async throws {
        guard isatty(STDIN_FILENO) == 1, arguments.count == 1, let path = arguments.first else { throw refused }
        let pin = try hailPin(atPath: path)
        try write(pin, to: pinFile)
        let summary = pin.teamID.map { "team \($0)" } ?? "cdhash \(pin.cdhash.map { String($0.prefix(12)) } ?? "?")"
        var message = "haild: trusted \(pin.identifier) (\(summary)) for private coaching\n"
        do {
            _ = try await AuditLog(directory: AuditHistory.standard().directory)
                .record(.coachingAppPinned(identifier: pin.identifier, pin: summary))
        } catch {
            // The running daemon holds the audit writer; `haild doctor` and the Mac card still show the pin.
            message += "haild: audit log busy or unavailable; the pin is shown by `haild doctor`\n"
        }
        FileHandle.standardError.write(Data(message.utf8))
    }

    /// Only a `.app` bundle at an absolute path whose signature names Hail's fixed bundle identifier.
    static func hailPin(atPath path: String) throws -> CoachingTrustedApp {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        guard path.hasPrefix("/"), url.pathExtension == "app" else { throw refused }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(url as CFURL, [], &code) == errSecSuccess, let code else { throw refused }
        let pin = try pin(for: code)
        guard pin.identifier == CoachingTrustedApp.hailBundleIdentifier else { throw refused }
        return pin
    }

    static var refused: CoachingParentRefusal { .unverified }

    /// A socketpair end has no path on either side; a connection accepted on a named socket does.
    private static func unnamed(_ descriptor: Int32, peer: Bool) -> Bool {
        var address = sockaddr_un()
        var length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let result = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                peer ? getpeername(descriptor, $0, &length) : getsockname(descriptor, $0, &length)
            }
        }
        guard result == 0, address.sun_family == sa_family_t(AF_UNIX) else { return false }
        let pathStart = MemoryLayout<sockaddr_un>.offset(of: \.sun_path) ?? 2
        return Int(length) <= pathStart || address.sun_path.0 == 0
    }

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
