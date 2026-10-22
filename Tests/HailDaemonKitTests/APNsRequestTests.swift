#if os(macOS)
import Foundation
import Testing
@testable import HailDaemonKit

/// #609 slice 1: an APNs request carries the token-auth header contract, the payload the design names (and, content
/// free, nothing that names a session or its words), and each answer maps to the design's action. Synthetic only.
@Suite struct APNsRequestTests {
    private static let token = String(repeating: "ab", count: 32)
    private static let id = UUID()
    private static let expiry = Date(timeIntervalSince1970: 1_800_003_600)

    private static func build(
        _ kind: APNsPush.Kind, content: APNsContent = .words, environment: APNsEnvironment = .production,
        topic: String = "com.example.Hail", providerToken: String = "jwt.synthetic.value"
    ) -> Result<APNsRequest, APNsRequest.Failure> {
        APNsRequest.make(APNsPush(kind: kind, expiry: expiry),
                         to: APNsTarget(deviceToken: token, environment: environment, topic: topic),
                         providerToken: providerToken, content: content)
    }

    private static func make(_ kind: APNsPush.Kind, content: APNsContent = .words,
                             environment: APNsEnvironment = .production) -> APNsRequest? {
        try? build(kind, content: content, environment: environment).get()
    }

    private static func json(_ request: APNsRequest) throws -> [String: Any] {
        try #require(JSONSerialization.jsonObject(with: request.body) as? [String: Any])
    }

    @Test func anUpdateCarriesTheTokenAuthHeaderContract() throws {
        let request = try #require(Self.make(.update(id: Self.id, session: "Deck", text: "The deck is built")))
        #expect(request.host == "api.push.apple.com" && request.path == "/3/device/\(Self.token)")
        #expect(request.headers == [
            "authorization": "bearer jwt.synthetic.value", "apns-topic": "com.example.Hail",
            "apns-push-type": "alert", "apns-priority": "10", "apns-expiration": "1800003600",
            "apns-collapse-id": Self.id.uuidString.lowercased()
        ])
        let sandbox = try #require(Self.make(.summary(count: 2), environment: .sandbox))
        #expect(sandbox.host == "api.sandbox.push.apple.com")
    }

    @Test func anUpdateWithWordsNamesTheSessionAndNeverACard() throws {
        let body = try Self.json(try #require(Self.make(.update(id: Self.id, session: "Deck", text: "Built"))))
        let aps = try #require(body["aps"] as? [String: Any])
        #expect(Set(aps.keys) == ["alert", "thread-id", "sound", "interruption-level"])
        #expect(aps["sound"] as? String == "default")
        #expect(aps["alert"] as? [String: String] == ["title": "Deck", "body": "Built"])
        #expect(aps["thread-id"] as? String == "Deck" && aps["interruption-level"] as? String == "active")
        let hail = try #require(body["hail"] as? [String: Any])
        #expect(Set(hail.keys) == ["update", "session", "priority"])
    }

    @Test func aContentFreePushNamesNeitherTheSessionNorItsWords() throws {
        let request = try #require(Self.make(.update(id: Self.id, session: "Deck", text: "Built"), content: .contentFree))
        let text = try #require(String(data: request.body, encoding: .utf8))
        #expect(!text.contains("Deck") && !text.contains("Built"))
        let body = try Self.json(request)
        let aps = try #require(body["aps"] as? [String: Any])
        #expect(Set(aps.keys) == ["alert", "sound", "interruption-level"])
        #expect(aps["alert"] as? [String: String] == ["title": "Hailing Station", "body": "An update is waiting"])
        #expect(Set(try #require(body["hail"] as? [String: Any]).keys) == ["update", "priority"])
        #expect(request.headers["apns-collapse-id"] == Self.id.uuidString.lowercased())
    }

    @Test func noDescriptionOrReflectionShowsTheProviderToken() throws {
        let request = try #require(Self.make(.update(id: Self.id, session: "Deck", text: "Built")))
        var dumped = ""
        dump(request, to: &dumped)
        for shown in [String(describing: request), String(reflecting: request), dumped, "\(request)"] {
            #expect(!shown.contains("jwt.synthetic.value") && !shown.contains(Self.token))
        }
        #expect(dumped.contains("bearer <redacted>"))
    }

    @Test func aSummaryUsesTheFixedCollapseID() throws {
        let request = try #require(Self.make(.summary(count: 3), content: .words))
        #expect(request.headers["apns-collapse-id"] == APNsRequest.summaryCollapseID)
        let aps = try #require(try Self.json(request)["aps"] as? [String: Any])
        #expect((aps["alert"] as? [String: String])?["body"] == "3 updates waiting")
    }

    @Test func aDeviceTokenThatIsNotLowercaseHexIsRefused() {
        for bad in [String(repeating: "AB", count: 32), "abc", String(repeating: "zz", count: 32),
                    String(repeating: "a", count: 63), String(repeating: "ab", count: 101)] {
            #expect(!APNsRequest.isDeviceToken(bad), "accepted \(bad.prefix(8))…")
        }
        let target = APNsTarget(deviceToken: "ABCD", environment: .production, topic: "t")
        let refused = APNsRequest.make(APNsPush(kind: .summary(count: 1), expiry: Self.expiry), to: target,
                                       providerToken: "p", content: .words)
        #expect(refused == .failure(.badDeviceToken))
    }

    @Test func aRequestWithoutTopicOrTokenOrThatIsTooLargeSaysWhy() {
        #expect(Self.build(.summary(count: 1), topic: "") == .failure(.noTopic))
        #expect(Self.build(.summary(count: 1), providerToken: "") == .failure(.noProviderToken))
        // Literal sizes: APNs's limit is 4096 bytes, whatever the constant says.
        let huge = String(repeating: "x", count: 4096)
        #expect(Self.build(.update(id: Self.id, session: "Deck", text: huge)) == .failure(.payloadTooLarge))
        let fits = String(repeating: "x", count: 3500)
        #expect((try? Self.build(.update(id: Self.id, session: "Deck", text: fits)).get()) != nil)
    }

    @Test func eachAnswerMapsToTheDesignedAction() {
        func outcome(_ status: Int, _ reason: String?) -> APNsOutcome {
            APNsOutcome.classify(status: status, body: reason.map { Data(#"{"reason":"\#($0)"}"#.utf8) })
        }
        #expect(outcome(200, nil) == .delivered)
        #expect(outcome(410, "Unregistered") == .removeToken(reason: "Unregistered"))
        #expect(outcome(410, "ExpiredToken") == .removeToken(reason: "ExpiredToken"))
        #expect(outcome(400, "BadDeviceToken") == .removeToken(reason: "BadDeviceToken"))
        #expect(outcome(403, "ExpiredProviderToken") == .refreshProviderToken(reason: "ExpiredProviderToken"))
        #expect(outcome(403, "InvalidProviderToken") == .refreshProviderToken(reason: "InvalidProviderToken"))
        #expect(outcome(403, "MissingProviderToken") == .refreshProviderToken(reason: "MissingProviderToken"))
        #expect(outcome(429, "TooManyProviderTokenUpdates") == .signingBug)
        #expect(outcome(429, "TooManyRequests") == .retry(after: 900, reason: "TooManyRequests"))
        #expect(outcome(503, nil) == .retry(after: 900, reason: "unknown"))
        #expect(outcome(400, "BadTopic") == .failed(status: 400, reason: "BadTopic"))
        #expect(outcome(403, "BadCertificate") == .failed(status: 403, reason: "BadCertificate"))
        #expect(outcome(400, "a secret path/with spaces") == .failed(status: 400, reason: "unknown"))
        #expect(outcome(400, String(repeating: "A", count: 65)) == .failed(status: 400, reason: "unknown"))
    }
}
#endif
