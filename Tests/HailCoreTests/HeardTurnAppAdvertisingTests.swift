import HailProtocol
import Testing
@testable import HailCore

/// C2 advertises support only once the app can present the model's refused-turn state (#923).
@MainActor
@Suite struct HeardTurnAppAdvertisingTests {
    @Test func deviceHelloAdvertisesHeardTurnsAlongsideHeardTextAndRefusals() async throws {
        let ready = try await readyHeardStore()
        let frames = try await ready.socket.sentFrames()
        if case .control(.hello(let hello))? = frames.first?.payload {
            #expect(hello.capabilities.contains(HeardTurns.capability))
            #expect(hello.capabilities.contains(AmbientHeard.capability))
            #expect(hello.capabilities.contains(RequestRefusals.capability))
        } else {
            Issue.record("expected the device hello first")
        }
        await ready.store.disconnect(ready.endpoint.id)
    }
}
