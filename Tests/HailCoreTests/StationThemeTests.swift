import Foundation
import HailCore
import SwiftUI
import Testing

@Suite("Astra station theme")
struct StationThemeTests {
    @Test(arguments: StationTheme.Role.allCases)
    func everyRoleDefinesTwoSRGBColours(_ role: StationTheme.Role) {
        let pair = StationTheme.astra[role]
        #expect(pair.light <= 0xFFFFFF)
        #expect(pair.dark <= 0xFFFFFF)
    }

    @Test @MainActor func sharedViewsOptInAndFollowTheSuppliedTheme() throws {
        var environment = EnvironmentValues()
        #expect(environment.activeStationPalette == nil)
        environment.stationTheme = StationTheme { _ in (0xFF0000, 0x0000FF) }
        environment.colorScheme = .light
        let light = try #require(environment.activeStationPalette)
        #expect(light[.brand] == Color(.sRGB, red: 1, green: 0, blue: 0))
        environment.colorScheme = .dark
        #expect(environment.stationPalette[.brand] == Color(.sRGB, red: 0, green: 0, blue: 1))
    }

    @Test(arguments: [false, true])
    func textAndControlContrast(dark: Bool) {
        typealias Role = StationTheme.Role
        let surfaces: [Role] = [.surface, .elevatedSurface, .sidebar]
        let labels: [Role] = [.textPrimary, .textSecondary, .brand, .statePrivate,
                              .stateLive, .stateWarning, .stateOffline]
        for background in surfaces {
            for foreground in labels {
                expectContrast(foreground, on: background, dark: dark)
            }
        }
        expectContrast(.statePrivate, on: .privateSurface, dark: dark)
        expectContrast(.stateLive, on: .privateSurface, dark: dark) // A live mic stays red on a private rail.
        expectContrast(.textPrimary, on: .warningSurface, dark: dark)
        expectContrast(.stateWarning, on: .warningSurface, dark: dark)
        expectContrast(.stateLive, on: .alertSurface, dark: dark)
        expectContrast(.onSidebarSelection, on: .sidebarSelection, dark: dark)
        expectContrast(.brandOnBrand, on: .brand, dark: dark)
        expectContrast(.brandOnBrand, on: .accentTalk, dark: dark)
        expectContrast(.brandOnBrand, on: .stateLive, dark: dark)
    }

    private func expectContrast(_ foreground: StationTheme.Role, on background: StationTheme.Role, dark: Bool) {
        func luminance(_ role: StationTheme.Role) -> Double {
            let swatch = StationTheme.astra[role]
            let rgb = dark ? swatch.dark : swatch.light
            func linear(_ shift: Int) -> Double {
                let value = Double((rgb >> shift) & 255) / 255
                return value <= 0.04045 ? value / 12.92 : pow((value + 0.055) / 1.055, 2.4)
            }
            return 0.2126 * linear(16) + 0.7152 * linear(8) + 0.0722 * linear(0)
        }
        let ink = luminance(foreground)
        let fill = luminance(background)
        let ratio = (max(ink, fill) + 0.05) / (min(ink, fill) + 0.05)
        #expect(ratio >= 4.5, "\(foreground) on \(background), dark=\(dark): \(ratio)")
    }
}
