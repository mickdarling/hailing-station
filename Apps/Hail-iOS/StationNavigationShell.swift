import HailCore
import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Renders navigation state and sends intents to the station root (#1115).
/// The capture surface stays mounted when a tool opens. On Mac it lives in the persistent detail column.
/// On iOS the detail itself can disappear (compact iPad Back), so the station tracks a slot from outside it.
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
        #if os(iOS)
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
                .allowsHitTesting(slot != nil)
            }
        #else
        arrangement
        #endif
    }

    @ViewBuilder
    private var arrangement: some View {
        switch state.layout(for: idiom) {
        case .split(let sidebarVisible):
            split(sidebarVisible: sidebarVisible)
        #if os(iOS)
        case .tabs(let tabBarVisible):
            VStack(spacing: 0) {
                pages
                if tabBarVisible {
                    StationTabBar(selection: state.section) { send(.select($0)) }
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .inspector(isPresented: inspectorPresented) { inspector() }
        #else
        case .tabs: pages
        #endif
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
            .toolbar(removing: isCollapsed ? nil : .sidebarToggle)
            .navigationTitle("Hailing Station")
            .navigationSplitViewColumnWidth(min: 180, ideal: 215, max: 260)
        } detail: {
            pages
                .toolbar {
                    if !isCollapsed {
                        ToolbarItem(placement: .navigation) {
                            Button(sidebarVisible ? "Hide Sidebar" : "Show Sidebar", systemImage: "sidebar.left") {
                                send(.setSidebarHidden(sidebarVisible))
                            }
                            .accessibilityIdentifier("shell.sidebar.toggle")
                        }
                    }
                }
                .inspector(isPresented: inspectorPresented) {
                    inspector()
                        .inspectorColumnWidth(min: 240, ideal: 275, max: 340)
                }
        }
        .navigationSplitViewStyle(.balanced)
    }

    /// Scope Mac navigation and hit testing to the detail. Only the visible tool section creates a tool stack.
    private var pages: some View {
        ZStack {
            #if os(macOS)
            let hidden = state.section != .station
            detail(.station)
                .stationAccessibilityScope()
                .safeAreaInset(edge: .bottom, spacing: 0) { dock(.station).stationAccessibilityScope() }
                .environment(\.stationAccessibilityHidden, hidden)
                .stationCollapsed(hidden)
                .onChange(of: hidden) { _, _ in announceLayoutChange() }
            #else
            if state.section == .station {
                // The slot starts below the iPad split view's Back and sidebar controls (#1148).
                Color.clear
                    .anchorPreference(key: StationSlotKey.self, value: .bounds) { $0 }
                    .navigationTitle(StationSection.station.title)
                    .accessibilityHidden(true)
            }
            #endif
            if state.section != .station {
                page(state.section).id(state.section)
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
        // SwiftUI hosts the inset separately from the root (#1183).
        .safeAreaInset(edge: .bottom, spacing: 0) { dock(section).stationAccessibilityScope() }
    }

    /// Refresh the restored station in the accessibility tree (#1183).
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
        Binding(get: { sidebarVisible ? .all : .detailOnly }, set: { visibility in
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
    StationNavigationShell(
        state: state, idiom: StationRedesignLaunch.idiom,
        send: { state.apply($0) },
        detail: { section in
            Text(section.title).frame(maxWidth: .infinity, maxHeight: .infinity).navigationTitle(section.title)
        },
        inspector: { Text("Inspector") },
        dock: { _ in Button("Full conversation") { state.apply(.toggleFullConversation) }.padding() }
    )
}
