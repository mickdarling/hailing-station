import Foundation
import HailProtocol

/// Ambient take-over as the station shows it (#366). The most recent device to start ambient listening on a host
/// holds it. The device that lost it is not in error: it shows where listening went and offers "Listen here". The
/// device that took it shows a brief, calm confirmation. Devices are named by class only.
public enum AmbientHandoff: Sendable, Equatable {
    /// Listening moved to another device of class `to` (`phone`, `pad`, `mac`, or nil when unknown).
    case movedAway(to: String?)
    /// This device's stream took listening over from a device of class `from` (nil when unknown).
    case movedHere(from: String?)

    /// The one-tap action on the device that lost listening. It starts listening here, the same take-over in reverse.
    public static let listenHereTitle = "Listen here"
    /// How long the confirmation on the device that took over stays up.
    public static let confirmationDuration: Duration = .seconds(4)

    /// The status line.
    public var status: String {
        switch self {
        case .movedAway(let kind):
            "Listening moved to \(Self.deviceName(kind) ?? "another device")"
        case .movedHere(let kind):
            Self.deviceName(kind).map { "Listening here now (moved from \($0))" } ?? "Listening here now"
        }
    }

    /// A spoken label for VoiceOver, with the action on the device that lost listening.
    public var accessibilityLabel: String {
        switch self {
        case .movedAway: "\(status). Tap \(Self.listenHereTitle) to listen on this device instead."
        case .movedHere: status
        }
    }

    /// A user-facing name for a device class, or nil for an unknown one. Never a device's own name.
    public static func deviceName(_ kind: String?) -> String? {
        switch AmbientTakeOver.deviceKind(kind) {
        case "phone": "iPhone"
        case "pad": "iPad"
        case "mac": "Mac"
        default: nil
        }
    }

    /// The take-over notice in a host refusal (`not_allowed: ambient moved to pad`), or nil for any other failure.
    public init?(refusal error: any Error) {
        guard case HostConnectionFailure.remote(let message) = error,
              let separator = message.range(of: ": ") else { return nil }
        let code = message[..<separator.lowerBound], detail = String(message[separator.upperBound...])
        let notice = AmbientTakeOver.moved(detail)
        guard code == ErrorCode.notAllowed.rawValue, notice.moved else { return nil }
        self = .movedAway(to: notice.to)
    }

    /// This device's class for its hello: `phone` or `pad` on iOS (from the hardware model, so it needs no main
    /// actor), `mac` on macOS, nil when unknown.
    public static let localDeviceKind: String? = {
        #if os(iOS)
        let model = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] ?? hardwareModel()
        if model.hasPrefix("iPad") { return "pad" }
        if model.hasPrefix("iPhone") { return "phone" }
        return nil
        #elseif os(macOS)
        return "mac"
        #else
        return nil
        #endif
    }()

    #if os(iOS)
    /// `uname`'s machine field, such as `iPhone15,3` or `iPad16,6`.
    private static func hardwareModel() -> String {
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(bytes: $0.prefix { $0 != 0 }, encoding: .utf8) } ?? ""
    }
    #endif
}
