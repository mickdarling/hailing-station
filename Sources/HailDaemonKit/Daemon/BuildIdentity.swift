import CryptoKit
public import Foundation

/// The running executable's identity: the first 16 hex characters of its SHA-256, the same prefix
/// `scripts/host.sh` names each installed release after (#246). The daemon and the CLI each hash their own
/// binary, so a mismatch is build skew (#115, #247) without any build-time stamping.
public enum BuildIdentity {
    /// `nil` when the file cannot be read in full.
    public static func digest(of executable: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: executable) else { return nil }
        defer { try? handle.close() }
        var hasher = SHA256()
        do {
            while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty { hasher.update(data: chunk) }
        } catch {
            return nil
        }
        return String(hasher.finalize().map { String(format: "%02x", $0) }.joined().prefix(16))
    }

    /// This process's executable, through any link (the `haild` on PATH links into a release).
    public static func current() -> String? {
        Bundle.main.executableURL.flatMap { digest(of: $0.resolvingSymlinksInPath()) }
    }
}
