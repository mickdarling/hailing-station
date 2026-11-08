/// The station's top-level navigation (#1115): which sections exist, how they are arranged on each device, and the
/// only changes a navigation view may ask for. It is presentation state. It holds no connection, audio, privacy,
/// recipient or target, and nothing here can start capture, change a destination or claim a host state.
public enum StationSection: String, CaseIterable, Identifiable, Sendable {
    /// The conversation, listening rail and voice dock.
    case station
    case sessions
    case devices
    case settings

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .station: "Station"
        case .sessions: "Sessions"
        case .devices: "Devices"
        case .settings: "Settings"
        }
    }

    public var systemImage: String {
        switch self {
        case .station: "waveform"
        case .sessions: "rectangle.stack"
        case .devices: "desktopcomputer"
        case .settings: "gearshape"
        }
    }
}

/// The device family, never the current width. It is fixed for the life of the app, so resizing an iPad window
/// (Slide Over, Stage Manager) never swaps the split view for tabs and remounts the conversation.
public enum StationNavigationIdiom: Sendable {
    case phone
    case pad
    case mac
}

/// How the sections are arranged.
public enum StationNavigationLayout: Equatable, Sendable {
    /// Mac and iPad: a sidebar beside the detail. The split view collapses it by itself at narrow widths.
    case split(sidebarVisible: Bool)
    /// iPhone: native tabs, with the voice dock above the tab bar.
    case tabs(tabBarVisible: Bool)
}

/// The only changes a navigation view sends. Each one is a request to the owner of `StationNavigationState`.
public enum StationNavigationIntent: Equatable, Sendable {
    case select(StationSection)
    case toggleInspector
    case toggleFullConversation
    /// The system's own sidebar control was used.
    case setSidebarHidden(Bool)
}

/// Owned above every navigation branch, by the station root, and passed down as a value.
public struct StationNavigationState: Equatable, Sendable {
    public private(set) var section: StationSection
    /// The user's inspector choice. Closed by default, so the conversation gets the width.
    public private(set) var inspectorPresented: Bool
    /// The conversation fills the window. It applies only to the station section.
    public private(set) var fullConversation: Bool
    public private(set) var sidebarHidden: Bool

    public init(
        section: StationSection = .station, inspectorPresented: Bool = false,
        fullConversation: Bool = false, sidebarHidden: Bool = false
    ) {
        self.section = section
        self.inspectorPresented = inspectorPresented
        self.fullConversation = fullConversation && section == .station
        self.sidebarHidden = sidebarHidden
    }

    /// Full conversation hides the sidebar or tab bar. The listening rail and voice dock are the detail's own and
    /// stay.
    public func layout(for idiom: StationNavigationIdiom) -> StationNavigationLayout {
        switch idiom {
        case .phone: .tabs(tabBarVisible: !fullConversation)
        case .pad, .mac: .split(sidebarVisible: !fullConversation && !sidebarHidden)
        }
    }

    /// Full conversation hides the inspector without forgetting that the user opened it.
    public var showsInspector: Bool { inspectorPresented && !fullConversation }

    public mutating func apply(_ intent: StationNavigationIntent) {
        switch intent {
        case .select(let next):
            section = next
            // Another section has no conversation to fill the window with, and full mode would hide the way back.
            if next != .station { fullConversation = false }
        case .toggleInspector:
            inspectorPresented.toggle()
            // Opening the inspector is a request to see it.
            if inspectorPresented { fullConversation = false }
        case .toggleFullConversation:
            guard section == .station else { return }
            fullConversation.toggle()
        case .setSidebarHidden(let hidden):
            sidebarHidden = hidden
            // Revealing the sidebar asks for navigation, which full mode hides.
            if !hidden { fullConversation = false }
        }
    }
}
