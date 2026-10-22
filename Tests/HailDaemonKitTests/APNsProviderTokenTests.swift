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

    /// A moment `minutes` after `base` on both clocks, or with the wall clock moved by `wallShift` minutes more.
    private static func moment(
        _ minutes: Int, after base: APNsMoment, wallShift: Int = 0
    ) -> APNsMoment {
        APNsMoment(wall: base.wall.addingTimeInterval(Double((minutes + wallShift) * 60)),
                   elapsed: base.elapsed + .seconds(minutes * 60))
    }

    private static let start = APNsMoment(wall: Date(timeIntervalSince1970: 1_800_000_000), elapsed: .now)

    @Test func theTokenIsReusedUntilFiftyMinutesOld() throws {
        let cache = APNsTokenCache(signer: try Self.signer().0)
        let first = cache.token(at: Self.start)
        #expect(cache.token(at: Self.moment(49, after: Self.start)) == first)
        let fresh = cache.token(at: Self.moment(50, after: Self.start))
        #expect(fresh != first)
        #expect(cache.token(at: Self.moment(51, after: Self.start)) == fresh)
    }

    @Test func aRefusalRefreshesOnlyOnceTwentyMinutesHavePassed() throws {
        let cache = APNsTokenCache(signer: try Self.signer().0)
        let first = cache.token(at: Self.start)
        #expect(cache.refreshAfterRefusal(at: Self.moment(19, after: Self.start)) == nil)
        #expect(cache.token(at: Self.moment(19, after: Self.start)) == first)
        let fresh = try #require(cache.refreshAfterRefusal(at: Self.moment(20, after: Self.start)))
        #expect(fresh != first)
        #expect(cache.refreshAfterRefusal(at: Self.moment(21, after: Self.start)) == nil)
    }

    /// Age is monotonic: a host wall clock jumped forward or back by an hour neither mints a token early nor lets a
    /// refusal refresh inside Apple's 20-minute limit. The new token still carries the wall time it was issued at.
    @Test func aWallClockJumpNeverChangesTheTokenAge() throws {
        let (signer, _) = try Self.signer()
        let cache = APNsTokenCache(signer: signer)
        let first = try #require(cache.token(at: Self.start))
        for shift in [60, -60] {
            #expect(cache.token(at: Self.moment(5, after: Self.start, wallShift: shift)) == first)
            #expect(cache.refreshAfterRefusal(at: Self.moment(5, after: Self.start, wallShift: shift)) == nil)
        }
        let later = Self.moment(50, after: Self.start, wallShift: 60)
        let fresh = try #require(cache.token(at: later))
        let claims = try JSONSerialization.jsonObject(with: Self.decode(fresh.split(separator: ".")[1]))
        #expect((claims as? [String: Any])?["iat"] as? Int == Int(later.wall.timeIntervalSince1970))
    }
}
#endif
