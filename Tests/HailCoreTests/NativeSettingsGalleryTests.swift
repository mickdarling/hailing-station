#if os(macOS)
import AppKit
import SwiftUI
import Testing

/// Optional exports are labelled native synthetic; bitmap output cannot establish installed-app or audio proof.
@MainActor
@Suite(.serialized) struct NativeSettingsGalleryTests {
    @Test func theSevenNativeSettingsRenderWithoutInvokingIntentsAndCanExportAGallery() async throws {
        let directory = try exportDirectory()
        var records: [[String: String]] = []
        for scheme in [ColorScheme.light, .dark] {
            let theme = scheme == .light ? "light" : "dark"
            for page in NativeSettingsGalleryPage.allCases {
                records.append(try await capture(page, name: "\(page.rawValue)-\(theme)-large",
                    style: .init(width: 900, scheme: scheme, typeSize: .large), output: directory))
            }
        }
        for page in [NativeSettingsGalleryPage.audio, .advanced, .listening] {
            records.append(try await capture(page, name: "\(page.rawValue)-light-narrow-requested-ax3",
                style: .init(width: 560, scheme: .light, typeSize: .accessibility3), output: directory))
        }
        #expect(records.count == 17)
        if let directory {
            let sourceHead = ProcessInfo.processInfo.environment["HAIL_SETTINGS_GALLERY_HEAD"] ?? "Not supplied"
            let manifest: [String: Any] = [
                "kind": "Native synthetic NSHostingView Settings fixtures; not the installed app",
                "headSuppliedByRunner": sourceHead,
                "notes": "Authored values, no normal RootView, OS read, permission, network or audio operation. "
                    + "Requested Mac Dynamic Type does not prove measured font scaling; iOS UI qualifies AX sizes.",
                "captures": records
            ]
            let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])
            try data.write(to: directory.appendingPathComponent("native-synthetic-manifest.json"), options: .atomic)
        }
    }

    private func capture(
        _ page: NativeSettingsGalleryPage, name: String, style: NativeSettingsGalleryStyle, output: URL?
    ) async throws -> [String: String] {
        let intents = NativeSettingsGalleryIntents()
        let host = NativeSettingsGalleryHost(scene: page.scene(intents: intents), width: style.width,
                                             scheme: style.scheme, typeSize: style.typeSize)
        defer { host.finish() }
        await host.render()
        let image = try host.png()
        #expect(intents.invocationCount == 0, "Rendering may not invoke any setting, navigation or OS-read intent")
        let filename = "native-synthetic-\(name).png"
        if let output { try image.data.write(to: output.appendingPathComponent(filename), options: .atomic) }
        return ["file": filename, "page": page.rawValue, "requestedLogicalWidth": String(Int(style.width)),
                "requestedLogicalHeight": "900", "pixelsWide": String(image.pixelsWide),
                "pixelsHigh": String(image.pixelsHigh), "pngBytes": String(image.data.count),
                "opaqueSampleFraction": String(image.opaqueSampleFraction),
                "backingScale": String(Double(image.pixelsWide) / Double(style.width))]
    }

    private func exportDirectory() throws -> URL? {
        guard let path = ProcessInfo.processInfo.environment["HAIL_SETTINGS_GALLERY_DIR"],
              !path.isEmpty else { return nil }
        try #require(path.hasPrefix("/"), "Gallery export needs an explicit absolute output directory")
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}

private struct NativeSettingsGalleryStyle {
    let width: CGFloat
    let scheme: ColorScheme
    let typeSize: DynamicTypeSize
}
#endif
