import Foundation
import HailCore

extension RootView {
    /// The hosts to restore. On a Mac, the first launch also adds the haild configured on this Mac, over loopback
    /// only (#266); a host the user later removes is not added again. iPhone and iPad restore exactly what was saved.
    @MainActor
    func withLocalHost(_ saved: [HostEndpoint]?) -> [HostEndpoint]? {
        #if os(macOS)
        let defaults = UserDefaults.standard
        let offered = defaults.bool(forKey: LocalHostBootstrap.offeredKey)
        let local = LocalHostBootstrap.endpoint(hostConfig: try? Data(contentsOf: LocalHostBootstrap.hostConfigURL))
        guard let added = LocalHostBootstrap.adding(local, to: saved ?? [], alreadyOffered: offered) else {
            return saved
        }
        defaults.set(true, forKey: LocalHostBootstrap.offeredKey)
        persist(added)
        return added
        #else
        saved
        #endif
    }
}
