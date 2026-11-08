import HailCore
import SwiftUI
#if os(iOS)
import UIKit
#endif

/// The station's native navigation (#1115): a sidebar split view on Mac and iPad, tabs on iPhone. It renders
/// `StationNavigationState` and sends `StationNavigationIntent`s; it owns no controller, connection, audio,
/// privacy, recipient or target. The production owners stay in the station root above it.
///
/// The station page is never unmounted by navigation. Its capture view finishes capture and clears a pending send
/// when it disappears, so other sections draw over it while it stays mounted, hidden and out of the accessibility
/// tree. For the same reason iPhone uses a native tab bar over the pages instead of a `TabView`, which would make
/// the station disappear on every tab switch.
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
        // The idiom never changes while the app runs, so this never swaps one arrangement for the other.
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
        #else
        // The Mac always resolves to a split view; this keeps the type total on every platform.
        pages
        #endif
    }

    /// The station page first and always; the selected other section, when there is one, above it.
    private var pages: some View {
        ZStack {
            page(.station)
                .stationCollapsed(state.section != .station)
            if state.section != .station {
                page(state.section)
                    .id(state.section)
            }
        }
    }

    private func page(_ section: StationSection) -> some View {
        NavigationStack { detail(section) }
            .safeAreaInset(edge: .bottom, spacing: 0) { dock(section) }
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

#if os(iOS)
/// The system tab bar on its own, so the pages above it stay mounted (see `StationNavigationShell`). It shows the
/// selection it is given and reports taps; it changes nothing itself.
struct StationTabBar: UIViewRepresentable {
    let selection: StationSection
    let select: (StationSection) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(select: select) }

    func makeUIView(context: Context) -> UITabBar {
        let bar = UITabBar()
        bar.items = StationSection.allCases.enumerated().map { index, section in
            let item = UITabBarItem(title: section.title, image: UIImage(systemName: section.systemImage), tag: index)
            item.accessibilityIdentifier = "station.tab.\(section.rawValue)"
            return item
        }
        bar.delegate = context.coordinator
        return bar
    }

    func updateUIView(_ bar: UITabBar, context: Context) {
        context.coordinator.select = select
        let index = StationSection.allCases.firstIndex(of: selection)
        bar.selectedItem = index.flatMap { bar.items?[$0] }
    }

    @MainActor
    final class Coordinator: NSObject, UITabBarDelegate {
        var select: (StationSection) -> Void

        init(select: @escaping (StationSection) -> Void) { self.select = select }

        func tabBar(_ tabBar: UITabBar, didSelect item: UITabBarItem) {
            let sections = StationSection.allCases
            guard sections.indices.contains(item.tag) else { return }
            select(sections[item.tag])
        }
    }
}
#endif

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
