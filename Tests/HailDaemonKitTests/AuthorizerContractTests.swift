import Foundation
import HailProtocol
import Testing
@testable import HailDaemonKit

/// The authorizer contract voice routing relies on (#636, review on #688): asking twice about one frame changes
/// nothing and gives the same answer, because a frame to a selected voice route is asked about as sent and as
/// delivered. Synthetic frames only.
@Suite struct AuthorizerContractTests {
    static let frames: [Frame] = [
        sessionFrame(target: "tmux:a", payload: .text(TextPayload(text: "synthetic"))),
        sessionFrame(target: "tmux:a", payload: .text(TextPayload(text: "partial", isFinal: false))),
        sessionFrame(payload: .control(.select(targetID: "tmux:a"))),
        sessionFrame(payload: .control(.listTargets))
    ]

    @Test func askingTwiceAboutAFrameGivesTheSameAnswerAndChangesNothing() async throws {
        let routes = try VoiceRoutes(defaultTarget: "tmux:a", routes: [.init(target: "tmux:a", name: "A")])
        let authorizers: [any HostSessionAuthorizing] = [
            ConnectionProbeAuthorizer(), PersonalTerminalAuthorizer(), PersonalTerminalAuthorizer().naming(routes)
        ]
        for authorizer in authorizers {
            let capabilities = authorizer.capabilities
            for frame in Self.frames {
                let first = await authorizer.authorize(frame)
                #expect(await authorizer.authorize(frame) == first)
            }
            #expect(authorizer.capabilities == capabilities)
        }
    }
}
