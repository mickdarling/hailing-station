import Foundation
import Testing
@testable import HailCore

@Suite("Local haild on this Mac")
struct LocalHostBootstrapTests {
    private func config(_ json: String) -> Data { Data(json.utf8) }

    @Test func loopbackBindUsesTheConfiguredPort() throws {
        let json = config(#"{"bind":"127.0.0.1","port":18765}"#)
        let endpoint = try #require(LocalHostBootstrap.endpoint(hostConfig: json))
        #expect(endpoint.url.absoluteString == "ws://127.0.0.1:18765")
        #expect(endpoint.id == LocalHostBootstrap.endpointID)
        #expect(endpoint.name == "This Mac")
    }

    @Test func wildcardBindsAreReachedOverLoopback() {
        #expect(LocalHostBootstrap.endpoint(hostConfig: config(#"{"bind":"0.0.0.0","port":8765}"#))?.url.absoluteString
            == "ws://127.0.0.1:8765")
        #expect(LocalHostBootstrap.endpoint(hostConfig: config(#"{"bind":"::","port":8765}"#))?.url.absoluteString
            == "ws://[::1]:8765")
    }

    @Test func nonLoopbackOrMissingConfigAddsNothing() {
        #expect(LocalHostBootstrap.endpoint(hostConfig: nil) == nil)
        #expect(LocalHostBootstrap.endpoint(hostConfig: config("not json")) == nil)
        #expect(LocalHostBootstrap.endpoint(hostConfig: config(#"{"bind":"100.64.0.1","port":8765}"#)) == nil)
        #expect(LocalHostBootstrap.endpoint(hostConfig: config(#"{"bind":"192.0.2.10","port":8765}"#)) == nil)
        #expect(LocalHostBootstrap.endpoint(hostConfig: config(#"{"bind":"127.0.0.1","port":0}"#)) == nil)
        #expect(LocalHostBootstrap.endpoint(hostConfig: config(#"{"bind":"127.0.0.1","port":"8765"}"#)) == nil)
        #expect(LocalHostBootstrap.endpoint(hostConfig: config(#"{"bind":"127.0.0.1"}"#)) == nil)
    }

    @Test func addedOnlyOnceAndNeverBesideAnotherLoopbackHost() throws {
        let local = try #require(LocalHostBootstrap.endpoint(hostConfig: config(#"{"bind":"127.0.0.1","port":8765}"#)))
        let remote = try HostEndpoint(id: "remote", name: "Studio", url: #require(URL(string: "ws://192.0.2.10:8765")))
        let loopback = try HostEndpoint(id: "mine", name: "Mine", url: #require(URL(string: "ws://localhost:9000")))

        #expect(LocalHostBootstrap.adding(local, to: [remote], alreadyOffered: false) == [remote, local])
        #expect(LocalHostBootstrap.adding(local, to: [], alreadyOffered: false) == [local])
        #expect(LocalHostBootstrap.adding(local, to: [remote], alreadyOffered: true) == nil)
        #expect(LocalHostBootstrap.adding(local, to: [loopback], alreadyOffered: false) == nil)
        #expect(LocalHostBootstrap.adding(local, to: [local], alreadyOffered: false) == nil)
        #expect(LocalHostBootstrap.adding(nil, to: [remote], alreadyOffered: false) == nil)
    }
}
