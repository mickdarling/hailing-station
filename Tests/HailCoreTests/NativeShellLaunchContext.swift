#if os(macOS)
import Foundation
import HailCore

/// One volatile preference and one actual production snapshot per process. Never writes app/disk preferences.
@MainActor
enum NativeShellLaunchContext {
    nonisolated static let optedIn = ProcessInfo.processInfo.environment["HAIL_NATIVE_SHELL_LIFETIME"] == "1"

    private static let configured: Bool = {
        let defaults = UserDefaults.standard
        let original = defaults.volatileDomain(forName: UserDefaults.argumentDomain)
        let existed = defaults.volatileDomainNames.contains(UserDefaults.argumentDomain)
        var temporary = original
        temporary[StationRedesignStep.shell.key] = optedIn
        defaults.setVolatileDomain(temporary, forName: UserDefaults.argumentDomain)
        defer {
            if existed {
                defaults.setVolatileDomain(original, forName: UserDefaults.argumentDomain)
            } else {
                defaults.removeVolatileDomain(forName: UserDefaults.argumentDomain)
            }
        }
        return StationRedesignLaunch.flags.isOn(.shell)
    }()

    static func install() { _ = configured }
}
#endif
