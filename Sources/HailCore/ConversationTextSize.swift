/// The conversation's own text size (#1115): the "Aa" choice, kept in the app and never in the system settings.
///
/// It multiplies on Dynamic Type rather than replacing it. The rendered size is `bodyScale × size`, where
/// `bodyScale` is the user's Dynamic Type scale for body text (1 at the default Large), so at the default size and
/// setting the transcript reads exactly as body text, and accessibility sizes still scale it. The largest step is
/// not a cap on the rendered size. It applies to transcript text only, never to app controls.
public struct ConversationTextSize: Equatable, Sendable {
    public enum Platform: Equatable, Sendable {
        /// iPhone and iPad.
        case touch
        case mac

        /// The sizes offered, in points at the default Dynamic Type setting.
        public var steps: [Int] {
            switch self {
            case .touch: [15, 16, 17, 19, 21, 24]
            case .mac: [12, 13, 14, 16, 18, 20]
            }
        }

        /// The app default, which Reset restores. It is not the system's setting.
        public var defaultSize: Int {
            switch self {
            case .touch: 17
            case .mac: 14
            }
        }
    }

    public enum Intent: Equatable, Sendable {
        case smaller, larger, reset
    }

    /// The app's own preference key. Only the owner at the app root reads and writes it; the control never does.
    public static let storageKey = "hailing-station.conversation-text-size.v1"

    public let platform: Platform
    /// The chosen size in points at the default Dynamic Type setting, always one of `platform.steps`.
    public let size: Int

    /// `stored` is the saved size in points. Nil or a value outside the offered range reads as the default. A value
    /// inside the range that isn't a step snaps to the nearest step, ties going smaller, so a later change to the
    /// list never sends anyone back to the default (Jarvis, PR 8 plan).
    public init(platform: Platform, stored: Int?) {
        self.platform = platform
        size = Self.step(for: stored, in: platform)
    }

    private init(platform: Platform, size: Int) {
        (self.platform, self.size) = (platform, size)
    }

    public var isDefault: Bool { size == platform.defaultSize }
    public var canShrink: Bool { size > platform.steps[0] }
    public var canGrow: Bool { size < platform.steps[platform.steps.count - 1] }

    /// The factor over the platform's default size: exactly 1 at the default.
    public var scale: Double { Double(size) / Double(platform.defaultSize) }

    /// The size to render, given the user's Dynamic Type scale for body text.
    public func pointSize(bodyScale: Double) -> Double { Double(size) * bodyScale }

    /// The value shown beside the control: "17 pt · default" or "19 pt".
    public var label: String { isDefault ? "\(size) pt · default" : "\(size) pt" }

    /// The value VoiceOver reads: "17 points, default" or "19 points".
    public var accessibilityValue: String { isDefault ? "\(size) points, default" : "\(size) points" }

    /// Shown at a bound, where one of Smaller or Larger can't be used.
    public var boundNote: String? {
        if !canShrink { return "Smallest" }
        if !canGrow { return "Largest" }
        return nil
    }

    /// The next state. Smaller and Larger stop at the bounds; Reset restores the app default.
    public func applying(_ intent: Intent) -> Self {
        let steps = platform.steps
        guard let index = steps.firstIndex(of: size) else { return Self(platform: platform, stored: nil) }
        let next = switch intent {
        case .smaller: steps[max(index - 1, 0)]
        case .larger: steps[min(index + 1, steps.count - 1)]
        case .reset: platform.defaultSize
        }
        return Self(platform: platform, size: next)
    }

    private static func step(for stored: Int?, in platform: Platform) -> Int {
        let steps = platform.steps
        guard let stored, let low = steps.first, let high = steps.last, (low...high).contains(stored) else {
            return platform.defaultSize
        }
        // The first step at the smallest distance, so a tie goes to the smaller size.
        return steps.min { abs($0 - stored) < abs($1 - stored) } ?? platform.defaultSize
    }
}
