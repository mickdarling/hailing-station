import HailCore
import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// The station's native navigation (#1115): a sidebar split view on Mac and iPad, tabs on iPhone. It renders
/// `StationNavigationState` and sends `StationNavigationIntent`s; it owns no controller, connection, audio,
/// privacy, recipient or target. The production owners stay in the station root above it.
///
/// The station page is never unmounted by navigation. Its capture view finishes capture and clears a pending send
/// when it disappears, so the page is not a child of any navigation container: a tab switch, another section or a
/// collapsed iPad split view going back to its sidebar would each remove it. It is drawn once, above the whole
/// arrangement, over a transparent slot in the detail. While no slot is shown it stays mounted, collapsed and out of
/// the accessibility tree. iPhone uses a native tab bar rather than a `TabView` for the same reason.
struct StationNavigationShell<Detail: View, Inspector: View, Dock: View>: View {
    let state: StationNavigationState
    let idiom: StationNavigationIdiom
    let send: (StationNavigationIntent) -> Void
    @ViewBuilder let detail: (StationSection) -> Detail
    @ViewBuilder let inspector: () -> Inspector
    /// Drawn in the bottom safe area of a section, above the tab bar on iPhone.
    @ViewBuilder let dock: (StationSection) -> Dock
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    #endif

    var body: some View {
        arrangement
            .overlayPreferenceValue(StationSlotKey.self) { slot in
                GeometryReader { proxy in
                    let frame = slot.map { proxy[$0] }
                    page(.station)
                        // Reaches every part of the page, which each hide themselves (`stationAccessibilityScope`).
                        .environment(\.stationAccessibilityHidden, frame == nil)
                        .frame(width: frame?.width ?? 0, height: frame?.height ?? 0)
                        .position(x: frame?.midX ?? 0, y: frame?.midY ?? 0)
                        .stationCollapsed(frame == nil)
                        .onChange(of: frame == nil) { _, _ in announceLayoutChange() }
                }
            }
    }

    /// The idiom never changes while the app runs, so this never swaps one arrangement for the other.
    @ViewBuilder
    private var arrangement: some View {
        switch state.layout(for: idiom) {
        case .split(let sidebarVisible):
            split(sidebarVisible: sidebarVisible)
        case .tabs(let tabBarVisible):
            tabs(tabBarVisible: tabBarVisible)
        }
    }

    private func split(sidebarVisible: Bool) -> some View {
        NavigationSplitView(columnVisibility: columnVisibility(sidebarVisible), preferredCompactColumn: compactColumn) {
            List(selection: sectionSelection) {
                ForEach(StationSection.allCases) { section in
                    Label(section.title, systemImage: section.systemImage)
                        .tag(section)
                        .accessibilityIdentifier("station.section.\(section.rawValue)")
                }
            }
            .navigationTitle("Hailing Station")
            .navigationSplitViewColumnWidth(min: 180, ideal: 215, max: 260)
        } detail: {
            pages
                .inspector(isPresented: inspectorPresented) {
                    inspector()
                        .inspectorColumnWidth(min: 240, ideal: 275, max: 340)
                }
        }
        .navigationSplitViewStyle(.balanced)
    }

    @ViewBuilder
    private func tabs(tabBarVisible: Bool) -> some View {
        #if os(iOS)
        VStack(spacing: 0) {
            pages
            // Full conversation hides the bar; the dock stays in the page's own safe area.
            if tabBarVisible {
                StationTabBar(selection: state.section) { send(.select($0)) }
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        // At compact width the system presents the inspector as a sheet.
        .inspector(isPresented: inspectorPresented) { inspector() }
        #else
        // The Mac always resolves to a split view; this keeps the type total on every platform.
        pages
        #endif
    }

    /// The selected section's page, or, for the station, the slot the station page is drawn over.
    private var pages: some View {
        ZStack {
            if state.section == .station {
                // The slot keeps the split view's own bar, which holds its Back and sidebar controls (Codex review
                // of #1148, round 3). Its bounds start below that bar, so the station page never covers them.
                Color.clear
                    .anchorPreference(key: StationSlotKey.self, value: .bounds) { $0 }
                    .navigationTitle(StationSection.station.title)
                    .accessibilityHidden(true)
            } else {
                page(state.section)
                    .id(state.section)
            }
        }
    }

    private func page(_ section: StationSection) -> some View {
        NavigationStack {
            // The station's root sits under the slot's bar, so it shows none of its own; a pushed tool keeps its own.
            if section == .station {
                detail(section).stationHiddenNavigationBar().stationAccessibilityScope()
            } else {
                detail(section)
            }
        }
        // The dock is hosted apart from the root too, so it hides with the station. It's empty until the dock step,
        // which must pass #1183's tree sweep; if this modifier doesn't reach the inset there, as it didn't reach the
        // build footer, that step must find another way that keeps the dock mounted.
        .safeAreaInset(edge: .bottom, spacing: 0) { dock(section).stationAccessibilityScope() }
    }

    /// Tells assistive technologies the tree changed, so a station shown again is read afresh. In #1183's iPad test,
    /// without it, the station shown again stayed out of the tree.
    private func announceLayoutChange() {
        #if os(iOS)
        UIAccessibility.post(notification: .layoutChanged, argument: nil)
        #else
        NSAccessibility.post(element: NSApp as Any, notification: .layoutChanged)
        #endif
    }

    private var sectionSelection: Binding<StationSection?> {
        Binding(get: { state.sidebarSelection(collapsed: isCollapsed) }, set: { next in
            if let next { send(.select(next)) }
        })
    }

    /// A split view collapses into one stack at compact width, which only an iPad window reaches.
    private var isCollapsed: Bool {
        #if os(iOS)
        sizeClass == .compact
        #else
        false
        #endif
    }

    private var compactColumn: Binding<NavigationSplitViewColumn> {
        Binding(get: { state.compactColumn == .sidebar ? .sidebar : .detail }, set: { column in
            send(.setCompactColumn(column == .sidebar ? .sidebar : .detail))
        })
    }

    private var inspectorPresented: Binding<Bool> {
        Binding(get: { state.showsInspector }, set: { shown in
            if shown != state.showsInspector { send(.toggleInspector) }
        })
    }

    private func columnVisibility(_ sidebarVisible: Bool) -> Binding<NavigationSplitViewVisibility> {
        Binding(get: { sidebarVisible ? .automatic : .detailOnly }, set: { visibility in
            send(.setSidebarHidden(visibility == .detailOnly))
        })
    }
}

/// Where the station page is drawn: the station slot's bounds, or nothing while no slot is shown.
private struct StationSlotKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil

    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}

#Preview("Navigation shell · synthetic") {
    @Previewable @State var state = StationNavigationState()
    #if os(iOS)
    let idiom: StationNavigationIdiom = UIDevice.current.userInterfaceIdiom == .pad ? .pad : .phone
    #else
    let idiom = StationNavigationIdiom.mac
    #endif
    StationNavigationShell(
        state: state, idiom: idiom,
        send: { state.apply($0) },
        detail: { section in
            Text(section.title).frame(maxWidth: .infinity, maxHeight: .infinity).navigationTitle(section.title)
        },
        inspector: { Text("Inspector") },
        dock: { _ in Button("Full conversation") { state.apply(.toggleFullConversation) }.padding() }
    )
}
