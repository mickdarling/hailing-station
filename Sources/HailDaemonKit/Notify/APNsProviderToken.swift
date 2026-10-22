import CryptoKit
import Foundation
import Synchronization

/// The provider token APNs requires for token-based authentication (#609, `docs/proactive-notifications.md`, "APNs
/// from haild"): an ES256 JSON Web Token over `{alg, kid}` and `{iss, iat}`, signed with the team's `.p8` key. The key
/// and every token are secrets: nothing here prints, logs or describes them.
struct APNsProviderToken: Sendable {
    enum Failure: Error, Equatable {
        /// The key ID or team ID is not 10 uppercase letters or digits, as Apple issues them.
        case badIdentifier
        /// The key file is not a PEM-encoded P-256 private key.
        case badKey
    }

    let keyID: String
    let teamID: String
    private let key: P256.Signing.PrivateKey

    init(keyID: String, teamID: String, pem: String) throws(Failure) {
        guard Self.isIdentifier(keyID), Self.isIdentifier(teamID) else { throw .badIdentifier }
        guard let key = try? P256.Signing.PrivateKey(pemRepresentation: pem) else { throw .badKey }
        (self.keyID, self.teamID, self.key) = (keyID, teamID, key)
    }

    /// A token issued at `issuedAt`: base64url header, claims and the raw 64-byte `r || s` signature, dot-joined. Nil
    /// only if CryptoKit fails to sign with a valid in-memory key; there is no token without a signature.
    func token(issuedAt: Date) -> String? {
        let header = Self.base64URL(Data(#"{"alg":"ES256","kid":"\#(keyID)"}"#.utf8))
        let claims = Self.base64URL(Data(#"{"iss":"\#(teamID)","iat":\#(Int(issuedAt.timeIntervalSince1970))}"#.utf8))
        let signed = "\(header).\(claims)"
        guard let signature = try? key.signature(for: Data(signed.utf8)) else { return nil }
        return "\(signed).\(Self.base64URL(signature.rawRepresentation))"
    }

    static func base64URL(_ data: Data) -> String {
        data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    private static func isIdentifier(_ value: String) -> Bool {
        value.utf8.count == 10 && value.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x41...0x5A).contains($0) }
    }
}

/// The token in use and when it was issued (#609). Apple accepts a token up to an hour old and refuses refreshes more
/// often than every 20 minutes (`429 TooManyProviderTokenUpdates`), so one is reused until 50 minutes old, and a `403`
/// may force a new one only once the current one is at least 20 minutes old. A host clock stepped back keeps the
/// cached token rather than minting new ones, and a failed signing is never cached.
final class APNsTokenCache: Sendable {
    static let minimumAge: TimeInterval = 20 * 60
    static let refreshAge: TimeInterval = 50 * 60

    private let signer: APNsProviderToken
    private let current = Mutex<(token: String, issued: Date)?>(nil)

    init(signer: APNsProviderToken) { self.signer = signer }

    /// The token to send now: the cached one while under 50 minutes old (or the clock has stepped back), else a fresh
    /// one. Nil only if signing failed.
    func token(now: Date) -> String? {
        current.withLock { cached in
            if let cached, now.timeIntervalSince(cached.issued) < Self.refreshAge { return cached.token }
            return Self.issue(signer, now: now, into: &cached)
        }
    }

    /// After APNs refused the provider token: a fresh one if the current one is at least 20 minutes old, else nil, so
    /// the refusal is reported rather than retried into Apple's refresh limit.
    func refreshAfterRefusal(now: Date) -> String? {
        current.withLock { cached in
            if let cached, (0..<Self.minimumAge).contains(now.timeIntervalSince(cached.issued)) { return nil }
            return Self.issue(signer, now: now, into: &cached)
        }
    }

    private static func issue(
        _ signer: APNsProviderToken, now: Date, into cached: inout (token: String, issued: Date)?
    ) -> String? {
        guard let token = signer.token(issuedAt: now) else { return nil }
        cached = (token, now)
        return token
    }
}
