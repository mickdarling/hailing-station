import Foundation
@testable import HailCore
import Testing

@Suite("Private coaching setup (#645)")
struct PrivateCoachingSetupTests {
    private static let local = """
    {"haild":"/synthetic/haild","rightyo":"/synthetic/rightyo","rightyoConfig":"/synthetic/config",
     "listenerProfile":"/synthetic/profile","listener":"owner","rendererOutputRoot":"/synthetic/out",
     "speechServices":"local"}
    """
    private static let hosted = """
    {"haild":"/synthetic/haild","rightyo":"/synthetic/rightyo","rightyoConfig":"/synthetic/config",
     "listenerProfile":"/synthetic/profile","listener":"owner","rendererOutputRoot":"/synthetic/out",
     "speechServices":"local","hosted":{"maxRequests":12,"adviceCatalog":"/synthetic/catalog"}}
    """

    @Test func localArgumentsCarryNoHostedFlags() throws {
        let setup = try PrivateCoachingSetup.parse(Data(Self.local.utf8))
        #expect(!setup.offersHosted)
        let arguments = try setup.arguments(privateOutput: 7, roomMicrophone: 9, provider: .local,
                                            hostedConsentConfirmed: true,
                                hostedSpeechConsentConfirmed: false)
        #expect(arguments.prefix(2) == ["coaching", "--parent-control"])
        #expect(!arguments.contains("--coaching-allow-hosted-text"))
        #expect(arguments.contains("7") && arguments.contains("9"))
        #expect(throws: PrivateCoachingSetup.SetupError.hostedNotConfigured) {
            try setup.arguments(privateOutput: 7, roomMicrophone: 9, provider: .hosted, hostedConsentConfirmed: true,
                                hostedSpeechConsentConfirmed: false)
        }
    }

    @Test func hostedArgumentsRequireConsent() throws {
        let setup = try PrivateCoachingSetup.parse(Data(Self.hosted.utf8))
        #expect(throws: PrivateCoachingSetup.SetupError.hostedConsentRequired) {
            try setup.arguments(privateOutput: 7, roomMicrophone: 9, provider: .hosted, hostedConsentConfirmed: false,
                                hostedSpeechConsentConfirmed: false)
        }
        let arguments = try setup.arguments(privateOutput: 7, roomMicrophone: 9, provider: .hosted,
                                            hostedConsentConfirmed: true,
                                hostedSpeechConsentConfirmed: false)
        #expect(arguments.suffix(7) == ["--coaching-provider", "jev", "--coaching-allow-hosted-text",
                                        "--coaching-max-requests", "12",
                                        "--coaching-advice-catalog", "/synthetic/catalog"])
        let local = try setup.arguments(privateOutput: 7, roomMicrophone: 9, provider: .local,
                                        hostedConsentConfirmed: true,
                                hostedSpeechConsentConfirmed: false)
        #expect(!local.contains("--coaching-allow-hosted-text"))
    }

    @Test func hostedSpeechSetupRefusesArgumentsWithoutItsConsent() throws {
        let text = Self.local.replacingOccurrences(of: "\"speechServices\":\"local\"",
                                                   with: "\"speechServices\":\"hosted\"")
        let setup = try PrivateCoachingSetup.parse(Data(text.utf8))
        #expect(throws: PrivateCoachingSetup.SetupError.hostedSpeechConsentRequired) {
            try setup.arguments(privateOutput: 7, roomMicrophone: 9, provider: .local, hostedConsentConfirmed: false,
                                hostedSpeechConsentConfirmed: false)
        }
        _ = try setup.arguments(privateOutput: 7, roomMicrophone: 9, provider: .local, hostedConsentConfirmed: false,
                                hostedSpeechConsentConfirmed: true)
    }

    @Test func aMissingSpeechDeclarationIsRefused() {
        let text = Self.local.replacingOccurrences(of: "\"speechServices\"", with: "\"unknownKey\"")
        #expect(throws: PrivateCoachingSetup.SetupError.invalid) { try PrivateCoachingSetup.parse(Data(text.utf8)) }
    }

    @Test func setupFileMustBeOwnerWritableAndNotASymlink() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("hailing-setup-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: root) }
        let file = root.appendingPathComponent("coaching-setup.json")
        // `/bin/sh` stands in for haild: root-owned and closed all the way up, so only the file's own state varies.
        try Data(Self.local.replacingOccurrences(of: "/synthetic/haild", with: "/bin/sh").utf8).write(to: file)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        #expect(try PrivateCoachingSetup.load(from: file).haild == "/bin/sh")
        let link = root.appendingPathComponent("link.json")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
        #expect(throws: PrivateCoachingSetup.SetupError.untrustedFile) { try PrivateCoachingSetup.load(from: link) }
        try FileManager.default.setAttributes([.posixPermissions: 0o620], ofItemAtPath: file.path)
        #expect(throws: PrivateCoachingSetup.SetupError.untrustedFile) { try PrivateCoachingSetup.load(from: file) }
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        let shared = root.appendingPathComponent("haild")
        try Data("#!/bin/sh\n".utf8).write(to: shared)
        try FileManager.default.setAttributes([.posixPermissions: 0o777], ofItemAtPath: shared.path)
        let path = root.resolvingSymlinksInPath().appendingPathComponent("haild").path
        try Data(Self.local.replacingOccurrences(of: "/synthetic/haild", with: path).utf8).write(to: file)
        #expect(throws: PrivateCoachingSetup.SetupError.untrustedFile) { try PrivateCoachingSetup.load(from: file) }
    }

    @Test func executableChecksRefuseSymlinksDotsDirectoriesAndSharedFiles() {
        #expect(PrivateCoachingSetup.trustedExecutable("/bin/sh"))
        #expect(!PrivateCoachingSetup.trustedExecutable("/tmp/../bin/sh"))
        #expect(!PrivateCoachingSetup.trustedExecutable("/bin"))
        #expect(!PrivateCoachingSetup.trustedExecutable("/etc/hosts")) // Under a symlinked directory.
        #expect(!PrivateCoachingSetup.trustedExecutable("bin/sh"))
    }

    @Test func sameOrUnknownDevicesAreRefused() throws {
        let setup = try PrivateCoachingSetup.parse(Data(Self.local.utf8))
        #expect(throws: PrivateCoachingSetup.SetupError.invalid) {
            try setup.arguments(privateOutput: 7, roomMicrophone: 7, provider: .local, hostedConsentConfirmed: false,
                                hostedSpeechConsentConfirmed: false)
        }
        #expect(throws: PrivateCoachingSetup.SetupError.invalid) {
            try setup.arguments(privateOutput: 0, roomMicrophone: 7, provider: .local, hostedConsentConfirmed: false,
                                hostedSpeechConsentConfirmed: false)
        }
    }

    @Test func relativePathsBadListenersAndBudgetsAreRefused() {
        let bad = [
            Self.local.replacingOccurrences(of: "/synthetic/rightyo", with: "synthetic/rightyo"),
            Self.local.replacingOccurrences(of: "\"owner\"", with: "\"own\\ner\""),
            Self.hosted.replacingOccurrences(of: "12", with: "0"),
            Self.hosted.replacingOccurrences(of: "12", with: "101"),
            "{}", ""
        ]
        for text in bad {
            #expect(throws: PrivateCoachingSetup.SetupError.invalid) { try PrivateCoachingSetup.parse(Data(text.utf8)) }
        }
    }
}
