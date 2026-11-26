/// The redesign's colour contract (#1115). Each role supplies two opaque 24-bit sRGB values.
/// A replacement theme must supply both appearances for every role.
public struct StationTheme: Sendable {
    public enum Role: CaseIterable, Sendable {
        case brand, brandOnBrand, accentTalk
        case surface, elevatedSurface, sidebar, separator
        case sidebarSelection, onSidebarSelection
        case textPrimary, textSecondary
        case statePrivate, stateLive, stateWarning, stateOffline
        case privateSurface, alertSurface
    }

    public typealias Swatch = (light: UInt32, dark: UInt32)
    private let swatch: @Sendable (Role) -> Swatch

    public init(swatch: @escaping @Sendable (Role) -> Swatch) {
        self.swatch = swatch
    }

    public subscript(role: Role) -> Swatch { swatch(role) }

    /// Astra design.css, :root and .dark. The quiet surface is --soft; --panel is the raised surface.
    /// The selected sidebar row and Talk use their own CSS rules, including distinct dark Talk ink.
    /// Offline shares the study's amber attention colour (NativeStudy's disconnected state).
    public static let astra = Self { role in
        switch role {
        case .brand: (0x176C5C, 0x91D5B0)
        case .brandOnBrand: (0xFFFFFF, 0x1C3529)
        case .accentTalk: (0x176C5C, 0x8DCBAA)
        case .surface: (0xF6F7F4, 0x26332C)
        case .elevatedSurface: (0xFFFFFF, 0x202C26)
        case .sidebar: (0xF4F5F2, 0x1D2922)
        case .separator: (0xE2E5DF, 0x38483D)
        case .sidebarSelection: (0xE2ECE2, 0x304836)
        case .onSidebarSelection: (0x244E3C, 0xE4F5DF)
        case .textPrimary: (0x202D2C, 0xE2EBE0)
        case .textSecondary: (0x65716C, 0xA0B19F)
        case .privateSurface: (0xF0EAFA, 0x3A3049)
        case .alertSurface: (0xFBECE7, 0x492E2A)
        case .statePrivate: (0x70509B, 0xCFB5EF)
        case .stateLive: (0xA44336, 0xF0AA99)
        case .stateWarning, .stateOffline: (0x8F570E, 0xF0C57C)
        }
    }
}
