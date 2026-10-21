import Foundation
import Testing
@testable import HailCore

@Suite("Local haild on this Mac")
struct LocalHostBootstrapTests {
    private func config(_ json: String) -> Data { Data(json.utf8) }

    private func url(bind: String, port: Int = 8765) -> String? {
        let json = #"{"bind":"\#(bind)","port":\#(port)}"#
        return LocalHostBootstrap.endpoint(hostConfig: config(json))?.url.absoluteString
    }

    @Test func loopbackBindUsesTheConfiguredPort() throws {
        let json = config(#"{"bind":"127.0.0.1","port":18765}"#)
        let endpoint = try #require(LocalHostBootstrap.endpoint(hostConfig: json))
        #expect(endpoint.url.absoluteString == "ws://127.0.0.1:18765")
        #expect(endpoint.id == LocalHostBootstrap.endpointID)
        #expect(endpoint.name == "This Mac")
        #expect(url(bind: "127.0.0.2") == "ws://127.0.0.2:8765")
    }

    @Test func wildcardBindsAreReachedOverLoopback() {
        #expect(url(bind: "0.0.0.0") == "ws://127.0.0.1:8765")
        #expect(url(bind: "::") == "ws://[::1]:8765")
        #expect(url(bind: "::1") == "ws://[::1]:8765")
    }

    @Test func onlyStrictLoopbackLiteralsAreAccepted() {
        for bind in [
            "127.+0.+0.+1", "127.-0.0.1", "127.00.0.1", "0127.0.0.1", "127.1", "127.0.0.1.", " 127.0.0.1",
            "localhost", "127.0.0.1.example", "::ffff:127.0.0.1", "::127.0.0.1", "100.64.0.1", "192.0.2.10", ""
        ] {
            #expect(url(bind: bind) == nil, "\(bind) must not be treated as loopback")
        }
    }

    @Test func missingOrMalformedConfigAddsNothing() {
        #expect(LocalHostBootstrap.endpoint(hostConfig: nil) == nil)
        #expect(LocalHostBootstrap.endpoint(hostConfig: config("not json")) == nil)
        #expect(url(bind: "127.0.0.1", port: 0) == nil)
        #expect(url(bind: "127.0.0.1", port: 65_536) == nil)
        #expect(LocalHostBootstrap.endpoint(hostConfig: config(#"{"bind":"127.0.0.1","port":"8765"}"#)) == nil)
        #expect(LocalHostBootstrap.endpoint(hostConfig: config(#"{"bind":"127.0.0.1"}"#)) == nil)
    }

    @Test func addedOnceThenARemovedHostStaysRemoved() throws {
        let local = try #require(LocalHostBootstrap.endpoint(hostConfig: config(#"{"bind":"127.0.0.1","port":8765}"#)))
        let remote = try HostEndpoint(id: "remote", name: "Studio", url: #require(URL(string: "ws://192.0.2.10:8765")))

        let first = LocalHostBootstrap.restore([remote], local: local, alreadyOffered: false)
        #expect(first == LocalHostBootstrap.Decision(hosts: [remote, local], offered: true))
        // The user removes it; the next launch sees the offer spent.
        let relaunch = LocalHostBootstrap.restore([remote], local: local, alreadyOffered: first.offered)
        #expect(relaunch == LocalHostBootstrap.Decision(hosts: nil, offered: true))
    }

    @Test func anExistingLoopbackHostSpendsTheOfferWithoutAdding() throws {
        let local = try #require(LocalHostBootstrap.endpoint(hostConfig: config(#"{"bind":"127.0.0.1","port":8765}"#)))
        for address in ["ws://localhost:9000", "ws://127.0.0.1:9000", "ws://[::1]:9000"] {
            let mine = try HostEndpoint(id: "mine", name: "Mine", url: #require(URL(string: address)))
            let decision = LocalHostBootstrap.restore([mine], local: local, alreadyOffered: false)
            #expect(decision == LocalHostBootstrap.Decision(hosts: nil, offered: true), "\(address)")
            // Removing that host later does not bring the local one back.
            #expect(LocalHostBootstrap.restore([], local: local, alreadyOffered: decision.offered).hosts == nil)
        }
    }

    @Test func noValidConfigLeavesTheOfferOpen() {
        #expect(LocalHostBootstrap.restore([], local: nil, alreadyOffered: false)
            == LocalHostBootstrap.Decision(hosts: nil, offered: false))
    }

    @Test func readsOnlyABoundedRegularFile() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = directory.appendingPathComponent("host.json")
        try config(#"{"bind":"127.0.0.1","port":8765}"#).write(to: file)
        #expect(LocalHostBootstrap.readConfig(at: file) != nil)

        let link = directory.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(LocalHostBootstrap.readConfig(at: link) == nil)

        let fifo = directory.appendingPathComponent("fifo.json")
        #expect(mkfifo(fifo.path, 0o600) == 0)
        #expect(LocalHostBootstrap.readConfig(at: fifo) == nil)

        let large = directory.appendingPathComponent("large.json")
        try Data(repeating: 0x20, count: LocalHostBootstrap.configByteLimit + 1).write(to: large)
        #expect(LocalHostBootstrap.readConfig(at: large) == nil)
        #expect(LocalHostBootstrap.readConfig(at: directory) == nil)
        #expect(LocalHostBootstrap.readConfig(at: directory.appendingPathComponent("absent.json")) == nil)
    }
}
