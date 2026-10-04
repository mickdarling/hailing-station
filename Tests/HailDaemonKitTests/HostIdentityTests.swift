import Testing
@testable import HailDaemonKit

@Suite struct HostIdentityTests {
    @Test func localHostNameWinsOverTheNetworkName() throws {
        let identity = try HostIdentity.resolve(
            environment: [:], localHostName: { "TheMachine" }, networkHostName: { "dhcp-42.example.net" }
        )
        #expect(identity == "themachine.local")
    }

    @Test func overrideIsCanonicalAndWinsOverEverything() throws {
        let identity = try HostIdentity.resolve(
            environment: [HostIdentity.environmentKey: "Studio.Example.NET."],
            localHostName: { "TheMachine" }, networkHostName: { "other" }
        )
        #expect(identity == "studio.example.net")
    }

    @Test func invalidOverrideIsRefusedNotIgnored() {
        #expect(throws: HostIdentityError.invalidOverride("bad host")) {
            try HostIdentity.resolve(
                environment: [HostIdentity.environmentKey: "bad host"],
                localHostName: { "TheMachine" }, networkHostName: { "other" }
            )
        }
    }

    @Test func networkNameIsUsedOnlyWithoutALocalHostName() throws {
        let identity = try HostIdentity.resolve(
            environment: [:], localHostName: { nil }, networkHostName: { "Mac-Mini.LAN." }
        )
        #expect(identity == "mac-mini.lan")
    }

    @Test func unusableNamesFallBackToLocalhost() throws {
        let identity = try HostIdentity.resolve(environment: [:], localHostName: { "" }, networkHostName: { "" })
        #expect(identity == "localhost")
    }

    @Test func canonicalRejectsNamesThatAreNotHostNames() {
        #expect(HostIdentity.canonical("") == nil)
        #expect(HostIdentity.canonical(".") == nil)
        #expect(HostIdentity.canonical("a..b") == nil)
        #expect(HostIdentity.canonical("a b") == nil)
        #expect(HostIdentity.canonical(String(repeating: "a", count: 254)) == nil)
        #expect(HostIdentity.canonical("Mac.Local.") == "mac.local")
    }
}
