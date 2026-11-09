import SwiftUI
#if os(iOS)
import UIKit
#endif

/// Hides a whole `NavigationStack` from accessibility: its root and any view pushed onto it (#1115).
///
/// The shell keeps the station page mounted while another section shows, collapsed and marked
/// `.accessibilityHidden`. That modifier sits outside the page's `NavigationStack` and doesn't reach the UIKit
/// navigation controller inside it, and a modifier on the stack's root wouldn't reach a pushed tool either, so
/// VoiceOver could still read the hidden station: its microphone and privacy state included. This hides the
/// navigation controller's own view instead, which covers everything the stack shows.
@MainActor
final class StationStackAccessibility {
    #if os(iOS)
    private weak var stackView: UIView?
    #endif

    /// Set by the shell from the station slot itself: hidden exactly while no slot shows the station.
    var hidden = false {
        didSet {
            guard hidden != oldValue else { return }
            apply()
            #if os(iOS)
            // Tells assistive technologies the tree changed, so a station shown again is read afresh. In #1183's iPad
            // test the root, hidden by SwiftUI, stayed out of the tree after it was shown again.
            UIAccessibility.post(notification: .layoutChanged, argument: nil)
            #endif
        }
    }

    #if os(iOS)
    fileprivate func attach(_ view: UIView) {
        stackView = view
        apply()
    }
    #endif

    private func apply() {
        #if os(iOS)
        stackView?.accessibilityElementsHidden = hidden
        #endif
    }
}

extension View {
    /// Placed on the stack's root: hides the root itself, and on iOS finds the stack for `accessibility`, whose flag
    /// is meant to cover a pushed view too.
    @ViewBuilder
    func stationStackAccessibility(_ accessibility: StationStackAccessibility, hidden: Bool) -> some View {
        #if os(iOS)
        background(StationStackProbe(accessibility: accessibility)).accessibilityHidden(hidden)
        #else
        accessibilityHidden(hidden)
        #endif
    }
}

#if os(iOS)
/// An empty view on the stack's root that finds the navigation controller hosting it.
private struct StationStackProbe: UIViewRepresentable {
    let accessibility: StationStackAccessibility

    func makeUIView(context: Context) -> ProbeView { ProbeView(accessibility: accessibility) }

    func updateUIView(_ view: ProbeView, context: Context) {}

    final class ProbeView: UIView {
        private let accessibility: StationStackAccessibility

        init(accessibility: StationStackAccessibility) {
            self.accessibility = accessibility
            super.init(frame: .zero)
            isAccessibilityElement = false
            isUserInteractionEnabled = false
        }

        @available(*, unavailable)
        required init?(coder: NSCoder) { nil }

        override func didMoveToWindow() {
            super.didMoveToWindow()
            guard window != nil else { return }
            var responder: UIResponder? = self
            while let current = responder {
                if let controller = current as? UIViewController, let stack = controller.navigationController {
                    accessibility.attach(stack.view)
                    return
                }
                responder = current.next
            }
        }
    }
}
#endif
