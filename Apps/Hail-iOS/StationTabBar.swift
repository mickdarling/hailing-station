import HailCore
import SwiftUI
#if os(iOS)
import UIKit

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
