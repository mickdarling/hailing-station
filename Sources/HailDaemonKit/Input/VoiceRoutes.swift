#if os(macOS)
public import Foundation
import HailProtocol

/// The owner's allow-list of sessions a request can be sent to by name (#636): "Voice Work, …" goes to the target
/// the owner named "Voice Work". The file names targets; it grants nothing. Every route still needs its own target
/// policy and binding, a route that lacks them is offline, and no target is ever discovered or trusted from a listing.
public struct VoiceRoutes: Sendable, Equatable {
    /// One named session: its exact target id, the name it is shown and spoken as, and other spellings it answers to
    /// (known misrecognitions such as "Voice Walk").
    public struct Route: Sendable, Equatable {
        public let target: String
        public let name: String
        public let aliases: [String]

        public init(target: String, name: String, aliases: [String] = []) {
            self.target = target
            self.name = name
            self.aliases = aliases
        }
    }

    public enum LoadError: Error, Equatable {
        case malformed, invalidTarget, invalidName, duplicateTarget, duplicateName, unknownDefault, unsafe
    }

    public static let maxRoutes = 16, maxAliases = 8, maxNameLength = 48
    /// The target a request that names no route goes to until the owner picks another.
    public let defaultTarget: String
    public let routes: [Route]
    /// Keyed spoken name or alias (`RightyoAddressing.key`) to its route.
    let keyed: [String: Route]

    public init(defaultTarget: String, routes: [Route]) throws {
        guard (1...Self.maxRoutes).contains(routes.count) else { throw LoadError.malformed }
        var keyed: [String: Route] = [:], targets: Set<String> = []
        for route in routes {
            guard route.target.contains(":"), (try? RightyoInputConsumer.validateTarget(route.target)) != nil else {
                throw LoadError.invalidTarget
            }
            guard targets.insert(route.target).inserted else { throw LoadError.duplicateTarget }
            guard route.aliases.count <= Self.maxAliases else { throw LoadError.invalidName }
            for spelling in [route.name] + route.aliases {
                let key = RightyoAddressing.key(spelling)
                guard Self.isName(spelling), !key.isEmpty, !VoiceMute.greetings.contains(key) else {
                    throw LoadError.invalidName
                }
                guard keyed[key] == nil else { throw LoadError.duplicateName }
                keyed[key] = route
            }
        }
        guard targets.contains(defaultTarget) else { throw LoadError.unknownDefault }
        self.defaultTarget = defaultTarget
        self.routes = routes
        self.keyed = keyed
    }

    /// Shown and spoken, so short, at most three words, and free of controls.
    private static func isName(_ spelling: String) -> Bool {
        (1...maxNameLength).contains(spelling.count) && spelling.split(separator: " ").count <= 3
            && !spelling.unicodeScalars.contains { CharacterSet.controlCharacters.contains($0) }
    }

    /// The route for an exact target id, for labelling a reply by the session that sent it; nil when it has none.
    public func route(for target: String) -> Route? {
        routes.first { $0.target == target }
    }

    /// `{"version": 1, "default": "tmux:a", "routes": [{"target": "tmux:a", "name": "Scratch", "aliases": [...]}]}`,
    /// with no other keys; nil when the file does not exist (routing is then off). The file decides where a spoken
    /// name's request goes, so it is trusted exactly as the destinations file is (`VoiceDestinations.trustedPath`).
    public static func load(_ url: URL) throws -> VoiceRoutes? {
        var info = stat()
        guard url.isFileURL, url.path.hasPrefix("/") else { throw LoadError.unsafe }
        if lstat(url.path, &info) != 0 {
            if errno == ENOENT { return nil }
            throw LoadError.unsafe
        }
        guard let path = VoiceDestinations.trustedPath(url.path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)) else { throw LoadError.unsafe }
        guard let raw = try? JSONDecoder().decode(JSONValue.self, from: data) else { throw LoadError.malformed }
        return try parse(raw)
    }

    private static func parse(_ raw: JSONValue) throws -> VoiceRoutes {
        guard case .object(let file) = raw, Set(file.keys) == ["version", "default", "routes"],
              file["version"] == .integer(1), case .string(let fallback)? = file["default"],
              case .array(let entries)? = file["routes"] else { throw LoadError.malformed }
        let routes = try entries.map { entry in
            guard case .object(let fields) = entry, Set(fields.keys).isSubset(of: ["target", "name", "aliases"]),
                  case .string(let target)? = fields["target"], case .string(let name)? = fields["name"] else {
                throw LoadError.malformed
            }
            var aliases: [String] = []
            switch fields["aliases"] {
            case nil: break
            case .array(let list)?:
                aliases = try list.map { value in
                    guard case .string(let alias) = value else { throw LoadError.malformed }
                    return alias
                }
            default: throw LoadError.malformed
            }
            return Route(target: target, name: name, aliases: aliases)
        }
        return try VoiceRoutes(defaultTarget: fallback, routes: routes)
    }
}
#endif
