#if DEBUG
import HailCore
import Testing

struct StationScreenSeedTests {
    @Test func fixtureArgumentsCannotOverrideTheEffectiveShellSnapshot() {
        let arguments = ["-reset-station-state", "-seed-navigation-shell", "-seed-station-screen", "ready"]
        let off = StationRedesignFlags { _ in false }
        let on = StationRedesignFlags { $0 == StationRedesignStep.shell.key }
        #expect(StationScreenSeed(arguments: arguments, flags: off) == nil)
        #expect(StationScreenSeed(arguments: arguments, flags: on) == .ready)
        #expect(StationScreenSeed(arguments: Array(arguments.dropFirst()), flags: on) == nil)
    }
}
#endif
