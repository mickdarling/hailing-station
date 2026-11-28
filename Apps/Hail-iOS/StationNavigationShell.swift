import HailCore
import SwiftUI
#if os(iOS)
import UIKit
#elseif os(macOS)
import AppKit
#endif

/// Keeps capture mounted in the Mac detail column or over the iOS detail slot, which can disappear on compact iPad.
struct StationNavigationShell<Detail: View, Inspector: View, Dock: View>: View {
    @Environment(\.stationPalette) private var palette
    let state: StationNavigationState
    let idiom: StationNavigationIdiom
    var session: DestinationLabel?
    let send: (StationNavigationIntent) -> Void
    @ViewBuilder let detail: (StationSection) -> Detail
    @ViewBuilder let inspector: () -> Inspector
    @ViewBuilder let dock: (StationSection) -> Dock
    #if os(iOS)
    @Environment(\.horizontalSizeClass) private var sizeClass
    private var isCollapsed: Bool { sizeClass == .compact }
    #else
    @State private var detailPath: [ShellTool] = []
    private var isCollapsed: Bool { false }
    #endif

    var body: some View {
        arrangement
            #if os(iOS)
            .overlayPreferenceValue(StationSlotKey.self) { slot in
                GeometryReader { proxy in
                    let frame = slot.map { proxy[$0] }
                    page(.station)
                        .environment(\.stationAccessibilityHidden, frame == nil)
                        .frame(width: frame?.width ?? 0, height: frame?.height ?? 0)
                        .position(x: frame?.midX ?? 0, y: frame?.midY ?? 0)
                        .stationCollapsed(frame == nil)
                        .onChange(of: frame == nil) {
                            UIAccessibility.post(notification: .layoutChanged, argument: nil)
                        }
                }
                .allowsHitTesting(slot != nil)
            }
            #endif
            .tint(palette[.brand])
            .foregroundStyle(palette[.textPrimary], palette[.textSecondary])
            .background(palette[.surface])
    }

    @ViewBuilder private var arrangement: some View {
        switch state.layout(for: idiom) {
        case .split(let sidebarVisible):
            split(sidebarVisible: sidebarVisible)
        #if os(iOS)
        case .tabs(let tabBarVisible):
            VStack(spacing: 0) {
                pages
                    // The overlaid Station stack is clipped to its slot. Paint behind it up to the status bar.
                    .background(state.section == .station ? palette[.elevatedSurface] : .clear,
                                ignoresSafeAreaEdges: .top)
                if tabBarVisible {
                    StationTabBar(selection: state.section) { send(.select($0)) }
                        .fixedSize(horizontal: false, vertical: true)
                        .background(palette[.elevatedSurface], ignoresSafeAreaEdges: .bottom)
                }
            }
            .inspector(isPresented: inspectorPresented) { inspector() }
        #else
        case .tabs: pages
        #endif
        }
    }

    private func split(sidebarVisible: Bool) -> some View {
        let toggle = ToolbarItem(placement: .navigation) {
            Button(sidebarVisible ? "Hide Sidebar" : "Show Sidebar", systemImage: "sidebar.left") {
                send(.setSidebarHidden(sidebarVisible))
            }
            .accessibilityIdentifier("shell.sidebar.toggle")
        }
        let column = pages
            #if os(iOS)
            .toolbar { if !isCollapsed { toggle } }
            #endif
        return NavigationSplitView(columnVisibility: columnVisibility(sidebarVisible),
                                   preferredCompactColumn: compactColumn) {
            StationSidebar(selection: sectionSelection, session: session)
                .toolbar(removing: isCollapsed ? nil : .sidebarToggle)
                .scrollContentBackground(.hidden)
                .background(palette[.sidebar])
                .navigationTitle(isCollapsed ? "Hailing Station" : "")
                .navigationSplitViewColumnWidth(min: 180, ideal: 215, max: 260)
        } detail: {
            if idiom == .mac, Inspector.self == EmptyView.self {
                column
            } else {
                column.inspector(isPresented: inspectorPresented) {
                    inspector().inspectorColumnWidth(min: 240, ideal: 275, max: 340)
                }
            }
        }
        .navigationSplitViewStyle(.balanced)
        #if os(macOS)
        .toolbar { toggle }
        .toolbarVisibility(.visible, for: .windowToolbar)
        #endif
    }

    #if os(macOS)
    private var pages: some View {
        let hidden = state.section != .station
        return VStack(spacing: 0) {
            GeometryReader { viewport in
                ZStack {
                    detail(.station)
                        .stationAccessibilityScope()
                        .environment(\.stationAccessibilityHidden, hidden)
                        .stationCollapsed(hidden)
                    // Keep the detail stack mounted so changing sections doesn't remount Station's capture surface.
                    NavigationStack(path: $detailPath) {
                        if hidden {
                            detail(state.section).id(state.section)
                                .scrollContentBackground(.hidden).background(palette[.surface])
                        }
                    }
                    .environment(\.shellDetailPath, $detailPath)
                    .stationCollapsed(!hidden)
                }
                .frame(width: viewport.size.width, height: viewport.size.height)
            }
            dock(state.section).fixedSize(horizontal: false, vertical: true)
        }
        .onChange(of: state.section) {
            detailPath.removeAll() // A pushed tool belongs to the section that opened it.
            NSAccessibility.post(element: NSApp as Any, notification: .layoutChanged)
        }
    }
    #else
    private var pages: some View {
        ZStack {
            if state.section == .station {
                Color.clear
                    .anchorPreference(key: StationSlotKey.self, value: .bounds) { $0 }
                    .navigationTitle(StationSection.station.title)
                    .accessibilityHidden(true)
            } else {
                page(state.section).id(state.section)
            }
        }
    }
    @ViewBuilder private func page(_ section: StationSection) -> some View {
        let stack = NavigationStack {
            if section == .station {
                detail(section).stationHiddenNavigationBar().stationAccessibilityScope()
            } else {
                detail(section).scrollContentBackground(.hidden).background(palette[.surface])
            }
        }
        if Dock.self == EmptyView.self {
            stack
        } else {
            stack.safeAreaInset(edge: .bottom, spacing: 0) { dock(section).stationAccessibilityScope() }
        }
    }
    #endif
}

private extension StationNavigationShell {
    var sectionSelection: Binding<StationSection?> {
        Binding(get: { state.sidebarSelection(collapsed: isCollapsed) }, set: { next in
            if let next { send(.select(next)) }
        })
    }

    var compactColumn: Binding<NavigationSplitViewColumn> {
        Binding(get: { state.compactColumn == .sidebar ? .sidebar : .detail }, set: { column in
            send(.setCompactColumn(column == .sidebar ? .sidebar : .detail))
        })
    }

    var inspectorPresented: Binding<Bool> {
        Binding(get: { state.showsInspector }, set: { shown in
            if shown != state.showsInspector { send(.toggleInspector) }
        })
    }

    func columnVisibility(_ sidebarVisible: Bool) -> Binding<NavigationSplitViewVisibility> {
        Binding(get: { sidebarVisible ? .all : .detailOnly }, set: { visibility in
            send(.setSidebarHidden(visibility == .detailOnly))
        })
    }
}

private struct StationSlotKey: PreferenceKey {
    static let defaultValue: Anchor<CGRect>? = nil
    static func reduce(value: inout Anchor<CGRect>?, nextValue: () -> Anchor<CGRect>?) {
        value = value ?? nextValue()
    }
}
