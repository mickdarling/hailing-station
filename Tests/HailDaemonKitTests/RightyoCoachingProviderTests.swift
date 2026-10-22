import Darwin
import Foundation
import Testing
@testable import HailDaemonKit

/// Pure argv/config validation only. This never launches Jev or invokes credentials/network/model code.
@Suite struct RightyoCoachingProviderTests {
    private let session = UUID().uuidString.lowercased()
    @Test func mockRemainsDefaultAndHostedTextIsASeparateExplicitCapability() throws {
        #expect(try RightyoCoachingLaunch().arguments(session: session, provenance: .synthetic) == ["--coaching"])
        let catalog = try fixture(Data("{\"step\":\"Ask for the next step.\"}".utf8))
        for budget in [1, 100] {
            let launch = RightyoCoachingLaunch(provider: .jev(hostedTextConsent: true,
                maxRequests: budget, adviceCatalog: catalog))
            let arguments = try launch.arguments(session: session, provenance: .liveMicrophone)
            #expect(arguments == ["--coaching", "--coaching-provider", "jev", "--coaching-allow-hosted-text",
                "--coaching-max-requests", String(budget), "--coaching-advice-catalog", catalog.path])
            #expect(!arguments.contains("--allow-hosted") && !arguments.contains("--use-jev"))
        }
    }
    @Test func missingConsentInvalidBudgetsAndMockMixingAreRefused() throws {
        let catalog = try fixture(Data("{}".utf8))
        for consent in [false, true] {
            for budget in [0, 1, 101] where !consent || budget != 1 {
                let launch = RightyoCoachingLaunch(provider: .jev(hostedTextConsent: consent,
                    maxRequests: budget, adviceCatalog: catalog))
                #expect(throws: RightyoChildError.unsafeConfig) {
                    try launch.arguments(session: session, provenance: .synthetic)
                }
            }
        }
        let mixed = RightyoCoachingLaunch(mockSuggestions: catalog,
            provider: .jev(hostedTextConsent: true, maxRequests: 1, adviceCatalog: catalog))
        #expect(throws: RightyoChildError.unsafeConfig) {
            try mixed.arguments(session: session, provenance: .synthetic)
        }
    }
    @Test func absoluteRegularBoundedReadableCatalogIsRequiredBeforeChildStart() throws {
        for data in [Data(), Data(repeating: 120, count: 8_193)] {
            let catalog = try fixture(data)
            #expect(throws: RightyoChildError.unsafeConfig) {
                try RightyoCoachingLaunch(provider: .jev(hostedTextConsent: true,
                    maxRequests: 1, adviceCatalog: catalog)).arguments(session: session, provenance: .synthetic)
            }
        }
        let file = try fixture(Data("{}".utf8)), fifo = file.deletingLastPathComponent().appendingPathComponent("fifo")
        guard mkfifo(fifo.path, 0o600) == 0 else { throw RightyoChildError.unsafeConfig }
        let remote = try #require(URL(string: "https://invalid.example/catalog"))
        for catalog in [fifo, file.deletingLastPathComponent(), remote] {
            #expect(throws: RightyoChildError.unsafeConfig) {
                try RightyoCoachingLaunch(provider: .jev(hostedTextConsent: true,
                    maxRequests: 1, adviceCatalog: catalog)).arguments(session: session, provenance: .synthetic)
            }
        }
    }
    private func fixture(_ data: Data) throws -> URL {
        let root = TestScratch.url("coaching-provider")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        let file = root.appendingPathComponent("catalog")
        try data.write(to: file)
        return file // Retain authored diagnostics, including failed cases.
    }
}
