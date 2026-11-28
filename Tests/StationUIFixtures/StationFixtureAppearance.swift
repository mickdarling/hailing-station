#if STATION_UI_FIXTURES && os(iOS) && targetEnvironment(simulator)
import notify
import SwiftUI

/// Apply the requested trait to the synthetic window, including changes while a seeded interaction is in progress.
struct StationFixtureAppearance: ViewModifier {
    let isFixture: Bool
    @State private var style = ProcessInfo.processInfo.environment[StationFixtureStyle.environmentKey]
        .flatMap(StationFixtureStyle.init(rawValue:))
    @State private var tokens: [Int32] = []

    func body(content: Content) -> some View {
        if isFixture, let style {
            content.overlay(alignment: .topLeading) { EffectiveFixtureStyle() }
                .preferredColorScheme(style == .dark ? .dark : .light)
                .onAppear(perform: observe)
                .onDisappear {
                    for token in tokens { notify_cancel(token) }
                    tokens.removeAll()
                }
        } else { content }
    }

    private func observe() {
        guard tokens.isEmpty else { return }
        for next in StationFixtureStyle.allCases {
            var token: Int32 = 0
            let status = notify_register_dispatch(next.notification, &token, .main) { _ in
                MainActor.assumeIsolated { style = next }
            }
            if status == NOTIFY_STATUS_OK { tokens.append(token) }
        }
    }
}

private struct EffectiveFixtureStyle: View {
    @Environment(\.colorScheme) private var scheme

    var body: some View {
        Color.clear.frame(width: 1, height: 1).allowsHitTesting(false)
            .accessibilityElement()
            .accessibilityLabel("Fixture appearance")
            .accessibilityValue(scheme == .dark ? "dark" : "light")
            .accessibilityIdentifier("fixture.color-scheme")
    }
}
#endif
