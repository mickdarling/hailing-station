#if DEBUG
import Foundation
import HailCore

/// Hostless window qualification. The destination browser and store still negotiate, list, select and confirm
/// their target. Only the isolated Mac test app and simulators can substitute this in-memory peer.
enum StationScreenSeed: String {
    case ready, offline, refused, held

    @MainActor static var requested: Self? {
        #if os(macOS)
        guard Bundle.main.bundleIdentifier == "com.mickdarling.Hail-macOS-shell-tests" else { return nil }
        #elseif !targetEnvironment(simulator)
        return nil
        #endif
        return Self(arguments: ProcessInfo.processInfo.arguments, flags: StationRedesignLaunch.flags)
    }

    init?(arguments: [String], flags: StationRedesignFlags) {
        guard flags.isOn(.shell), arguments.contains("-seed-navigation-shell"), arguments.contains("-reset-station-state"),
              let index = arguments.firstIndex(of: "-seed-station-screen"),
              arguments.indices.contains(index + 1) else { return nil }
        self.init(rawValue: arguments[index + 1])
    }
}
#endif
