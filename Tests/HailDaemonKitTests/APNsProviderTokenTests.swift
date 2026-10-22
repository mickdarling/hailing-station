#if os(macOS)
import CryptoKit
import Foundation
import Testing
@testable import HailDaemonKit

/// #609 slice 1: the APNs provider token is an ES256 JWT that verifies against the key's public half, carries the key
/// and team IDs, and is reused and refreshed inside Apple's limits. A throwaway key made per test; never a real one.
@Suite struct APNsProviderTokenTests {
    private static let keyID = "ABC123DEFG", teamID = "TEAM456789"

    private static func signer() throws -> (APNsProviderToken, P256.Signing.PublicKey) {
        let key = P256.Signing.PrivateKey()
        return (try APNsProviderToken(keyID: keyID, teamID: teamID, pem: key.pemRepresentation), key.publicKey)
    }

    private static func decode(_ part: Substring) throws -> Data {
        var text = part.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        text += String(repeating: "=", count: (4 - text.count % 4) % 4)
        return try #require(Data(base64Encoded: text))
    }

    @Test func aTokenIsAnES256JWTOverTheKeyAndTeam() throws {
        let (signer, publicKey) = try Self.signer()
        let issued = Date(timeIntervalSince1970: 1_800_000_000)
        let parts = try #require(signer.token(issuedAt: issued)).split(separator: ".")
        try #require(parts.count == 3)
        let header = try JSONSerialization.jsonObject(with: Self.decode(parts[0])) as? [String: Any]
        let claims = try JSONSerialization.jsonObject(with: Self.decode(parts[1])) as? [String: Any]
        #expect(header?["alg"] as? String == "ES256" && header?["kid"] as? String == Self.keyID)
        #expect(claims?["iss"] as? String == Self.teamID && claims?["iat"] as? Int == 1_800_000_000)
        #expect(!parts.joined().contains("="), "base64url is unpadded")
        let signature = try P256.Signing.ECDSASignature(rawRepresentation: Self.decode(parts[2]))
        #expect(publicKey.isValidSignature(signature, for: Data("\(parts[0]).\(parts[1])".utf8)))
    }

    @Test func malformedIdentifiersOrKeysAreRefused() throws {
        let pem = P256.Signing.PrivateKey().pemRepresentation
        let unsafe = [("ABC123DEF\"", Self.teamID), (Self.keyID, "TEAM45678\\"), ("ABC123DEF\u{0}", Self.teamID)]
        for (key, team) in [("abc123defg", Self.teamID), ("ABC123", Self.teamID), (Self.keyID, "TEAM45678!")] + unsafe {
            #expect(throws: APNsProviderToken.Failure.badIdentifier) {
                try APNsProviderToken(keyID: key, teamID: team, pem: pem)
            }
        }
        #expect(throws: APNsProviderToken.Failure.badKey) {
            try APNsProviderToken(keyID: Self.keyID, teamID: Self.teamID, pem: "not a key")
        }
        let otherCurve = P384.Signing.PrivateKey().pemRepresentation
        #expect(throws: APNsProviderToken.Failure.badKey) {
            try APNsProviderToken(keyID: Self.keyID, teamID: Self.teamID, pem: otherCurve)
        }
    }

    @Test func theTokenIsReusedUntilFiftyMinutesOld() throws {
        let cache = APNsTokenCache(signer: try Self.signer().0)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let first = cache.token(now: start)
        #expect(cache.token(now: start.addingTimeInterval(49 * 60)) == first)
        let fresh = cache.token(now: start.addingTimeInterval(50 * 60))
        #expect(fresh != first)
        #expect(cache.token(now: start.addingTimeInterval(51 * 60)) == fresh)
    }

    @Test func aRefusalRefreshesOnlyOnceTwentyMinutesHavePassed() throws {
        let cache = APNsTokenCache(signer: try Self.signer().0)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let first = cache.token(now: start)
        #expect(cache.refreshAfterRefusal(now: start.addingTimeInterval(19 * 60)) == nil)
        #expect(cache.token(now: start.addingTimeInterval(19 * 60)) == first)
        let fresh = try #require(cache.refreshAfterRefusal(now: start.addingTimeInterval(20 * 60)))
        #expect(fresh != first)
        #expect(cache.refreshAfterRefusal(now: start.addingTimeInterval(21 * 60)) == nil)
    }

    /// A host clock stepped back keeps the cached token rather than minting one per step into Apple's refresh limit;
    /// a refusal then may refresh, since the cached token's age is unknown.
    @Test func aClockSteppedBackKeepsTheTokenUntilRefused() throws {
        let cache = APNsTokenCache(signer: try Self.signer().0)
        let start = Date(timeIntervalSince1970: 1_800_000_000)
        let first = try #require(cache.token(now: start))
        #expect(cache.token(now: start.addingTimeInterval(-60)) == first)
        #expect(cache.token(now: start.addingTimeInterval(-3600)) == first)
        let fresh = try #require(cache.refreshAfterRefusal(now: start.addingTimeInterval(-60)))
        #expect(fresh != first)
    }
}
#endif
