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
    private let window: TestHostWindow

    init(model: AudioRouteModel, typeSize: DynamicTypeSize = .large) {
        window = TestHostWindow(size: NSSize(width: 480, height: 900))
        let root = NavigationStack {
            AudioSettingsOverview(model: model).environment(HostConnectionStore())
        }
        .environment(\.dynamicTypeSize, typeSize)
        .environment(\.accessibilityEnabled, true)
        .transaction { $0.disablesAnimations = true; $0.animation = nil }
        hosting = NSHostingView(rootView: AnyView(root))
        window.mount(hosting)
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
        var search = AudioSettingsAccessibilityTraversal()
        guard let row = search.find("settings.audio.\(name)", in: hosting) else { return "" }
        var reading = AudioSettingsAccessibilityTraversal()
        return reading.read(row).joined(separator: " ")
    }

    func hide() { hosting.rootView = AnyView(Text("Closed")) }
    func finish() { window.close() }
}

/// SwiftUI virtual nodes need not subclass NSObject. Match the established native Appearance traversal:
/// typed AX getters, navigation-order/backing/contents children, attributed strings and bounded identity dedup.
@MainActor
private struct AudioSettingsAccessibilityTraversal {
    private var seen: Set<ObjectIdentifier> = []

    mutating func find(_ identifier: String, in value: Any) -> (any NSObjectProtocol)? {
        guard let object = visit(value) else { return nil }
        if Self.text(attribute("accessibilityIdentifier", on: object)) == identifier { return object }
        for child in children(of: object) {
            if let found = find(identifier, in: child) { return found }
        }
        return nil
    }

    mutating func read(_ value: Any) -> [String] {
        guard let object = visit(value) else { return [] }
        let own: [Any?]
        if let full = object as? any NSAccessibilityProtocol {
            own = [full.accessibilityLabel(), full.accessibilityValue(), full.accessibilityTitle(),
                   full.accessibilityValueDescription()]
        } else {
            own = [attribute("accessibilityLabel", on: object), attribute("accessibilityValue", on: object),
                   attribute("accessibilityTitle", on: object), attribute("accessibilityValueDescription", on: object)]
        }
        var result = own.compactMap(Self.text)
        for child in children(of: object) { result += read(child) }
        return result
    }

    private mutating func visit(_ value: Any) -> (any NSObjectProtocol)? {
        guard let object = value as? any NSObjectProtocol,
              seen.count < 512, seen.insert(ObjectIdentifier(object as AnyObject)).inserted else { return nil }
        return object
    }

    private func children(of object: any NSObjectProtocol) -> [Any] {
        let navigation: [Any], regular: [Any], contents: [Any]
        if let full = object as? any NSAccessibilityProtocol {
            navigation = (full.accessibilityChildrenInNavigationOrder() ?? []).map { $0 as Any }
            regular = full.accessibilityChildren() ?? []
            contents = full.accessibilityContents() ?? []
        } else {
            navigation = (attribute("accessibilityChildrenInNavigationOrder", on: object) as? [Any]) ?? []
            regular = (attribute("accessibilityChildren", on: object) as? [Any]) ?? []
            contents = (attribute("accessibilityContents", on: object) as? [Any]) ?? []
        }
        return navigation + regular + contents
    }

    private func attribute(_ name: String, on object: any NSObjectProtocol) -> AnyObject? {
        let selector = NSSelectorFromString(name)
        guard object.responds(to: selector) else { return nil }
        // Every selected getter returns an object; do not use perform(_:) for struct-valued AX getters.
        return object.perform(selector)?.takeUnretainedValue()
    }

    private static func text(_ value: Any?) -> String? {
        if let text = value as? String { return text }
        return (value as? NSAttributedString)?.string
    }
}
#endif
