import Foundation

/// Part of #1012: scale wall-clock assertions on CI while keeping local bounds strict.
enum TestTiming {
    static func factor(environment: [String: String]) -> Double {
        if let raw = environment["HAIL_CI_TIME_SCALE"], let value = Double(raw), value.isFinite, value > 0 {
            return value
        }
        return environment["CI"] == "true" ? 3 : 1
    }

    static func bound(_ seconds: Double) -> Double {
        seconds * factor(environment: ProcessInfo.processInfo.environment)
    }
}
