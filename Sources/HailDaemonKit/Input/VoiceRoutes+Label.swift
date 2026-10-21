#if os(macOS)
public import Foundation

extension VoiceRoutes {
    /// `routes.json` beside the policy: `~/.config/hail`, or `HAIL_CONFIG_DIR` when set.
    public static func standardFile(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        PolicyFile.standard(environment: environment).directory.appendingPathComponent("routes.json")
    }

    /// The spoken form of a reply from `target` (#636): a route other than the default speaks its name first
    /// ("Deck: …"), so the owner hears which session answered. The default route and any target that is not a route
    /// speak as before. The name is the owner's, looked up by the exact target id, never text the caller supplied.
    public func spoken(_ say: String, from target: String) -> String {
        guard target != defaultTarget, let route = route(for: target) else { return say }
        return "\(route.name): \(say)"
    }
}
#endif
