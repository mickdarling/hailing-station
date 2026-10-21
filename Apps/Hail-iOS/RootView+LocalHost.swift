import Foundation
import HailCore

extension RootView {
    /// The hosts to restore. On a Mac, the first launch also adds the haild configured on this Mac, over loopback
    /// only (#266); once offered it is never added again, so a removed local host stays removed. iPhone and iPad
    /// restore exactly what was saved.
    @MainActor
    func withLocalHost(_ saved: [HostEndpoint]?) async -> [HostEndpoint]? {
        #if os(macOS)
        let defaults = UserDefaults.standard
        let offered = defaults.bool(forKey: LocalHostBootstrap.offeredKey)
        guard !offered else { return saved }
        let url = LocalHostBootstrap.hostConfigURL
        let config = await Task.detached { LocalHostBootstrap.readConfig(at: url) }.value
        let decision = LocalHostBootstrap.restore(
            saved ?? [], local: LocalHostBootstrap.endpoint(hostConfig: config), alreadyOffered: offered
        )
        if decision.offered { defaults.set(true, forKey: LocalHostBootstrap.offeredKey) }
        guard let hosts = decision.hosts else { return saved }
        persist(hosts)
        return hosts
        #else
        saved
        #endif
    }
}
