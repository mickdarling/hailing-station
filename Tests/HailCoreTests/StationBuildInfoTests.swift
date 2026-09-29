import Foundation
@testable import HailCore
import Testing

@Suite struct StationBuildInfoTests {
    @Test func preservesExactMarketingVersionAndUploadBuild() {
        let info = StationBuildInfo(infoDictionary: [
            "CFBundleShortVersionString": "2.7.14",
            "CFBundleVersion": "17903665926944790",
            "CFBundleIdentifier": "ignored.example"
        ])
        #expect(info.version == "2.7.14")
        #expect(info.build == "17903665926944790")
        #expect(info.label == "Version 2.7.14 · Build 17903665926944790")
    }

    @Test func readsReleaseMetadataFromTheSuppliedBundle() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString).appendingPathExtension("bundle")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let metadata = [
            "CFBundleIdentifier": "example.station-build-info-test",
            "CFBundleShortVersionString": "4.2.1",
            "CFBundleVersion": "987654321"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0)
        try data.write(to: directory.appendingPathComponent("Info.plist"))
        let bundle = try #require(Bundle(url: directory))
        #expect(StationBuildInfo(bundle: bundle).label == "Version 4.2.1 · Build 987654321")
    }

    @Test func missingOrInvalidValuesAreExplicitlyUnavailable() {
        #expect(StationBuildInfo(infoDictionary: [:]).label == "Version Unavailable · Build Unavailable")
        let info = StationBuildInfo(infoDictionary: ["CFBundleShortVersionString": " \n", "CFBundleVersion": 42])
        #expect(info.version == "Unavailable")
        #expect(info.build == "Unavailable")
        let partial = StationBuildInfo(infoDictionary: ["CFBundleShortVersionString": "1.2.3"])
        #expect(partial.label == "Version 1.2.3 · Build Unavailable")
    }
}
