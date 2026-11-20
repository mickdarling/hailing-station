#if os(macOS)
import AppKit
import HailCore
import SwiftUI

struct AudioSettingsTestSnapshot: Sendable {
    let diagnostics: AudioSessionDiagnostics
    let inputs: [AudioPort]
    let preferred: AudioPort?
    let selection: AudioInputSelectionState
}

/// No system audio backend: every read, subscription and mutation is recorded.
actor AudioSettingsOwnerSpy: AudioInputSelectionProviding {
    private var snapshot: AudioSettingsTestSnapshot
    private(set) var calls: [String] = []

    init(_ snapshot: AudioSettingsTestSnapshot) { self.snapshot = snapshot }
    func set(_ snapshot: AudioSettingsTestSnapshot) { self.snapshot = snapshot }
    func clearCalls() { calls = [] }

    var diagnostics: AudioSessionDiagnostics {
        calls.append("diagnostics")
        return snapshot.diagnostics
    }
    var availableInputs: [AudioPort] {
        calls.append("inputs")
        return snapshot.inputs
    }
    var preferredInput: AudioPort? {
        calls.append("preferred")
        return snapshot.preferred
    }
    var inputSelectionState: AudioInputSelectionState {
        calls.append("selection")
        return snapshot.selection
    }
    var events: AsyncStream<AudioSessionEvent> {
        calls.append("events")
        return AsyncStream { $0.finish() }
    }
    func activate() async throws { calls.append("activate") }
    func deactivate() async { calls.append("deactivate") }
    func selectInput(id: AudioPort.ID?) async throws { calls.append("select") }
    func retryInputSelection() async throws { calls.append("retry") }
}

/// Hosts the shipped model-to-view adapter, including its actual existing-tool destination.
@MainActor
final class NativeAudioSettingsHost {
    private let hosting: NSHostingView<AnyView>
    private let window: NSWindow

    init(model: AudioRouteModel, typeSize: DynamicTypeSize = .large) {
        _ = NSApplication.shared
        let root = NavigationStack {
            AudioSettingsOverview(model: model).environment(HostConnectionStore())
        }
        .environment(\.dynamicTypeSize, typeSize)
        .environment(\.accessibilityEnabled, true)
        .transaction { $0.disablesAnimations = true; $0.animation = nil }
        hosting = NSHostingView(rootView: AnyView(root))
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 480, height: 900),
                          styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = hosting
        window.orderBack(nil)
    }

    func render() async {
        for _ in 0..<4 {
            hosting.needsLayout = true
            hosting.layoutSubtreeIfNeeded()
            await withCheckedContinuation { continuation in
                DispatchQueue.main.async { continuation.resume() }
            }
        }
    }

    func rowText(_ name: String) -> String {
        guard let row = find("settings.audio.\(name)", in: hosting) else { return "" }
        return text(in: row).joined(separator: " ")
    }

    func hide() { hosting.rootView = AnyView(Text("Closed")) }
    func finish() { window.close() }

    private func attribute(_ name: String, of object: NSObject) -> AnyObject? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return nil }
        return object.perform(selector)?.takeUnretainedValue()
    }

    private func children(of object: NSObject) -> [NSObject] {
        ((attribute("accessibilityChildren", of: object) as? [Any]) ?? []).compactMap { $0 as? NSObject }
    }

    private func find(_ identifier: String, in object: NSObject) -> NSObject? {
        if attribute("accessibilityIdentifier", of: object) as? String == identifier { return object }
        return children(of: object).lazy.compactMap { find(identifier, in: $0) }.first
    }

    private func text(in object: NSObject) -> [String] {
        let own = [attribute("accessibilityLabel", of: object) as? String,
                   attribute("accessibilityValue", of: object) as? String].compactMap { $0 }
        return own + children(of: object).flatMap { text(in: $0) }
    }
}
#endif
