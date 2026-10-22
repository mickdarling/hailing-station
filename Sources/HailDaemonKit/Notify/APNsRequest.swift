import Foundation

/// One push haild asks APNs to deliver (#609, `docs/proactive-notifications.md`): an `action` update, or the summary
/// that stands for several once the hourly cap is reached. Card text is never pushed.
struct APNsPush: Sendable, Equatable {
    enum Kind: Sendable, Equatable {
        case update(id: UUID, session: String, text: String)
        /// "N updates waiting", under a fixed collapse ID so a later summary replaces an earlier one.
        case summary(count: Int)
    }

    let kind: Kind
    /// When APNs should stop trying: the update's expiry, as wall-clock time.
    let expiry: Date
}

/// What a push may show (#609, open question 1): the update's words, or nothing that names a session or what it said.
enum APNsContent: Sendable, Equatable {
    case words, contentFree
}

/// The APNs environment a device token belongs to, and the host that serves it.
enum APNsEnvironment: String, Sendable, Equatable, CaseIterable {
    case production, sandbox

    var host: String { self == .production ? "api.push.apple.com" : "api.sandbox.push.apple.com" }
}

/// Where a push goes: one device token, the environment it belongs to, and the app's bundle ID as the APNs topic.
struct APNsTarget: Sendable, Equatable {
    let deviceToken: String
    let environment: APNsEnvironment
    let topic: String
}

/// One HTTP/2 request to APNs: the path, the header contract and the JSON payload. Building it touches no network.
/// Its `authorization` header holds a live provider token, so every description and reflection redacts it.
struct APNsRequest: Sendable, Equatable, CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    static let summaryCollapseID = "hail-updates-waiting"
    static let maxPayloadBytes = 4096

    let host: String
    let path: String
    let headers: [String: String]
    let body: Data

    /// Why no request was built, as a reason token for the caller to report.
    enum Failure: String, Error, Equatable {
        case badDeviceToken = "bad_device_token", noTopic = "no_topic", noProviderToken = "no_provider_token"
        case payloadTooLarge = "payload_too_large"
    }

    /// The request, or why not: a device token that is not lowercase hex of a plausible length (never normalised), an
    /// empty topic or provider token, or a payload too large for APNs.
    static func make(
        _ push: APNsPush, to target: APNsTarget, providerToken: String, content: APNsContent
    ) -> Result<APNsRequest, Failure> {
        guard isDeviceToken(target.deviceToken) else { return .failure(.badDeviceToken) }
        guard !target.topic.isEmpty else { return .failure(.noTopic) }
        guard !providerToken.isEmpty else { return .failure(.noProviderToken) }
        guard let body = try? JSONSerialization.data(withJSONObject: payload(push, content: content),
                                                     options: [.sortedKeys]),
              body.count <= maxPayloadBytes else { return .failure(.payloadTooLarge) }
        let collapse: String
        switch push.kind {
        case .update(let id, _, _): collapse = id.uuidString.lowercased()
        case .summary: collapse = summaryCollapseID
        }
        let headers = [
            "authorization": "bearer \(providerToken)", "apns-topic": target.topic, "apns-push-type": "alert",
            "apns-priority": "10", "apns-expiration": String(Int(push.expiry.timeIntervalSince1970)),
            "apns-collapse-id": collapse
        ]
        return .success(APNsRequest(
            host: target.environment.host, path: "/3/device/\(target.deviceToken)", headers: headers, body: body
        ))
    }

    /// Redacted: no provider token and no device token.
    var description: String { "APNsRequest(\(host)/3/device/<redacted>, \(body.count) bytes)" }
    var debugDescription: String { description }
    var customMirror: Mirror {
        var shown = headers
        shown["authorization"] = shown["authorization"].map { _ in "bearer <redacted>" }
        return Mirror(self, children: [
            "host": host, "path": "/3/device/<redacted>", "headers": shown, "bodyBytes": body.count
        ])
    }

    static func isDeviceToken(_ token: String) -> Bool {
        (16...200).contains(token.utf8.count) && token.utf8.count.isMultiple(of: 2)
            && token.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    private static func payload(_ push: APNsPush, content: APNsContent) -> [String: Any] {
        var aps: [String: Any] = ["sound": "default", "interruption-level": "active"]
        var hail: [String: Any] = ["priority": SessionUpdatePriority.action.rawValue]
        switch (push.kind, content) {
        case let (.update(id, session, text), .words):
            aps["alert"] = ["title": session, "body": text]
            aps["thread-id"] = session
            hail["update"] = id.uuidString.lowercased()
            hail["session"] = session
        case let (.update(id, _, _), .contentFree):
            aps["alert"] = ["title": "Hailing Station", "body": "An update is waiting"]
            hail["update"] = id.uuidString.lowercased()
        case let (.summary(count), _):
            aps["alert"] = ["title": "Hailing Station", "body": "\(count) updates waiting"]
            hail["summary"] = count
        }
        return ["aps": aps, "hail": hail]
    }
}
