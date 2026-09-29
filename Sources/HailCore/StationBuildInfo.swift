public import Foundation

/// Only the installed app's public release identifiers belong on the Station footer.
public struct StationBuildInfo: Equatable, Sendable {
    public let version: String
    public let build: String

    public init(bundle: Bundle = .main) {
        self.init(infoDictionary: bundle.infoDictionary ?? [:])
    }

    init(infoDictionary: [String: Any]) {
        version = Self.releaseValue(infoDictionary["CFBundleShortVersionString"])
        build = Self.releaseValue(infoDictionary["CFBundleVersion"])
    }

    public var label: String { "Version \(version) · Build \(build)" }

    private static func releaseValue(_ value: Any?) -> String {
        guard let text = value as? String,
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return "Unavailable"
        }
        return text
    }
}
