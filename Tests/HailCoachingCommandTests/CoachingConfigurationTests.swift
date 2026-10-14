import Foundation
import Testing
@testable import haild
@testable import HailCoaching

@Suite struct CoachingConfigurationTests {
    private var arguments: [String] {
        ["--rightyo", "/synthetic/rightyo", "--rightyo-config", "/synthetic/config",
         "--listener-profile", "/synthetic/profile", "--listener", "private-coach", "--private-output", "101",
         "--room-microphone", "102", "--renderer-output-root", "/synthetic/owned"]
    }
    @Test func explicitDistinctLocalIDsParseWithoutQueryingHardwareOrStartingAnything() throws {
        let selected = try CoachingConfiguration.parse(arguments)
        #expect(selected.privateOutput == 101 && selected.roomMicrophone == 102)
        #expect(selected.listenerID == "private-coach" && selected.executable.path == "/synthetic/rightyo")
    }
    @Test func missingRepeatedUnknownOrAmbiguousChoicesFailClosed() {
        for input in [[], Array(arguments.dropLast()), arguments + ["--listener", "other"],
                      arguments + ["--target", "remote"], arguments + ["--allow-hosted", "yes"]] {
            #expect(throws: CoachingCommandError.invalidConfiguration) { try CoachingConfiguration.parse(input) }
        }
        for invalid in ["0", "102", "-1", "4294967296", "headphones", "1.0"] {
            var input = arguments; input[9] = invalid
            #expect(throws: CoachingCommandError.invalidConfiguration) { try CoachingConfiguration.parse(input) }
        }
        var relative = arguments; relative[1] = "rightyo"
        #expect(throws: CoachingCommandError.invalidConfiguration) { try CoachingConfiguration.parse(relative) }
        for listener in [" ", "   "] {
            var input = arguments; input[7] = listener
            #expect(throws: CoachingCommandError.invalidConfiguration) { try CoachingConfiguration.parse(input) }
        }
    }
}
