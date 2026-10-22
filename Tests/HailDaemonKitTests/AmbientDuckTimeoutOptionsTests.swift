import Foundation
import Testing
@testable import HailDaemonKit

/// `--ambient-duck-timeout` (#735 H-2), from host.json `ambient.duckTimeout`: whole seconds from a minute to twelve
/// hours, once, only with the ambient set; absent, duck mode ends itself after an hour.
@Suite(.frozenGuardBudget) struct AmbientDuckTimeoutOptionsTests {
    static let head = AmbientWiringOptionsTests.base + AmbientWiringOptionsTests.personal
    static let ambient = AmbientWiringOptionsTests.ambient

    @Test func theDefaultIsThreeHoursAndAbsentLeavesIt() throws {
        #expect(AmbientRightyoRouter.defaultDuckTimeout == 3600)
        #expect(AmbientRightyoRouter.duckTimeoutRange.contains(AmbientRightyoRouter.defaultDuckTimeout))
        #expect(try ConnectionProbeDaemon.options(Self.head + Self.ambient).ambient?.duckTimeout == nil)
    }

    @Test(arguments: [("60", 60.0), ("5400", 5400.0), ("14400", 14_400.0)])
    func aTimeoutInRangeRidesWithTheAmbientFlags(_ value: String, _ seconds: TimeInterval) throws {
        let options = try ConnectionProbeDaemon.options(Self.head + Self.ambient + ["--ambient-duck-timeout", value])
        #expect(options.ambient?.duckTimeout == seconds)
    }

    static let refused: [[String]] = [
        head + ["--ambient-duck-timeout", "600"],
        head + ambient + ["--ambient-duck-timeout", "59"],
        head + ambient + ["--ambient-duck-timeout", "14401"],
        head + ambient + ["--ambient-duck-timeout", "43200"],
        head + ambient + ["--ambient-duck-timeout", "0"],
        head + ambient + ["--ambient-duck-timeout", "-600"],
        head + ambient + ["--ambient-duck-timeout", "600.5"],
        head + ambient + ["--ambient-duck-timeout", "1e3"],
        head + ambient + ["--ambient-duck-timeout", "/600"],
        head + ambient + ["--ambient-duck-timeout", "0000600"],
        head + ambient + ["--ambient-duck-timeout", ""],
        head + ambient + ["--ambient-duck-timeout"],
        head + ambient + ["--ambient-duck-timeout", "600", "--ambient-duck-timeout", "900"]
    ]

    @Test(arguments: refused)
    func refusedTimeouts(_ arguments: [String]) {
        #expect(throws: WebSocketListenerError.invalidArguments) { try ConnectionProbeDaemon.options(arguments) }
    }
}

#if os(macOS)
@Suite(.timeLimit(.minutes(1)), .frozenGuardBudget) struct AmbientDuckTimeoutStartupTests {
    /// The parsed timeout is the router's; without one the router keeps the default.
    @Test func theTimeoutReachesTheRouter() async throws {
        let rig = try await RecipientTestRig.make()
        let fake = try FakeRightyo("exit 0")
        defer { fake.cleanUp() }
        var options = ConnectionProbeDaemon.AmbientOptions(
            executable: fake.executable, config: fake.config, target: RecipientTestRig.target
        )
        let fallback = try await ConnectionProbeDaemon.ambientRouter(options, host: rig.host, log: { _ in })
        #expect(fallback.configuration.duckTimeout == AmbientRightyoRouter.defaultDuckTimeout)
        options.duckTimeout = 5400
        let configured = try await ConnectionProbeDaemon.ambientRouter(options, host: rig.host, log: { _ in })
        #expect(configured.configuration.duckTimeout == 5400)
    }
}
#endif
