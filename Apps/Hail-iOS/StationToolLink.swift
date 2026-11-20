import HailCore
import SwiftUI

/// A link from the station to one of its tools (#1115).
///
/// Today it pushes the tool onto the station's stack, as before. In the redesign's navigation shell the station stays
/// mounted but hidden while another section shows, and anything pushed under it would be hidden with it, so there the
/// shell supplies `stationSectionOpener` and the link opens the tool's section instead: Devices for Mac Setup,
/// Settings for Audio, Labs and Turn-taking. Without an opener, nothing changes.
struct StationToolLink<Destination: View, Title: View>: View {
    /// The section that lists this tool in the shell.
    let section: StationSection
    @ViewBuilder let destination: () -> Destination
    @ViewBuilder let label: () -> Title
    @Environment(\.stationSectionOpener) private var opener

    var body: some View {
        if let opener {
            Button { opener.open(section) } label: { label() }
        } else {
            NavigationLink { destination() } label: { label() }
        }
    }
}

/// Opens a section of the redesign's navigation shell. It only asks the shell's owner to select a section.
@MainActor
final class StationSectionOpener {
    let open: (StationSection) -> Void

    init(_ open: @escaping (StationSection) -> Void) {
        self.open = open
    }
}

extension EnvironmentValues {
    /// Set only by the navigation shell, for the station page. Nil everywhere else, so links push as they always have.
    var stationSectionOpener: StationSectionOpener? {
        get { self[StationSectionOpenerKey.self] }
        set { self[StationSectionOpenerKey.self] = newValue }
    }
}

private struct StationSectionOpenerKey: EnvironmentKey {
    static let defaultValue: StationSectionOpener? = nil
}
