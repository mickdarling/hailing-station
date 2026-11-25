import Foundation
import Testing

@Test func mountedTalkSupportLinksTheAppSession() throws {
    let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    let link = tests.appendingPathComponent("StationTalkTestSupport/StationTalkSession.swift")
    let appFile = tests.deletingLastPathComponent().appendingPathComponent("Apps/Hail-iOS/StationTalkSession.swift")
    #expect(try link.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true)
    #expect(link.resolvingSymlinksInPath() == appFile.resolvingSymlinksInPath())
}
