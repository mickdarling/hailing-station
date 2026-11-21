#if os(macOS)
import Foundation
import HailCore

/// One volatile preference and one actual production snapshot per process. Never writes app/disk preferences.
@MainActor
enum NativeShellLaunchContext {
    nonisolated static let optedIn = ProcessInfo.processInfo.environment["HAIL_NATIVE_SHELL_LIFETIME"] == "1"

    private static let configured: Bool = {
        guard optedIn else { return StationRedesignLaunch.flags.isOn(.shell) }
        let defaults = UserDefaults.standard
        let original = defaults.volatileDomain(forName: NSArgumentDomain)
        let existed = defaults.volatileDomainNames.contains(NSArgumentDomain)
        var temporary = original
        temporary[StationRedesignStep.shell.key] = true
        defaults.setVolatileDomain(temporary, forName: NSArgumentDomain)
        defer {
            if existed { defaults.setVolatileDomain(original, forName: NSArgumentDomain) }
            else { defaults.removeVolatileDomain(forName: NSArgumentDomain) }
        }
        return StationRedesignLaunch.flags.isOn(.shell)
    }()

    static func install() { _ = configured }
}
#endif
