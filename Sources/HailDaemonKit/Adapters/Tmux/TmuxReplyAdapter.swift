import Foundation
import HailProtocol

public enum TmuxReplyAdapterError: Error, Sendable, Equatable {
    case invalidConfiguration, contextRequired, invalidText
}

/// Opt-in input to a programmatic JSON-line bridge, never a metadata prefix for ordinary shell/TUI input.
/// The bridge must retain `request` outside model text and return it through `haild reply --request` (#161).
/// Registering this adapter grants neither target policy authority nor output capture.
public actor TmuxReplyAdapter: ProviderContextDelivering {
    public nonisolated let kind = "tmux-reply"
    public nonisolated let inputShape = AdapterInputShape.singleLineContextual
    public static let configurationVariable = "HAIL_REPLY_BRIDGE_TARGETS"
    public static let maxConfiguredTargets = 16
    private let terminal: TmuxAdapter
    private let targets: Set<String>

    /// Explicit local configuration names adapter-local sessions running a trusted programmatic bridge.
    /// Absent configuration is off; malformed configuration fails closed without echoing its contents.
    public static func configuredTargets(in environment: [String: String]) throws -> Set<String> {
        guard let value = environment[configurationVariable] else { return [] }
        guard value.utf8.count <= 8 * 1_024,
              let names = try? JSONDecoder().decode([String].self, from: Data(value.utf8)) else {
            throw TmuxReplyAdapterError.invalidConfiguration
        }
        let targets = Set(names)
        guard targets.count == names.count else { throw TmuxReplyAdapterError.invalidConfiguration }
        try validate(targets)
        return targets
    }

    public init(terminal: TmuxAdapter, targets: Set<String>) throws {
        try Self.validate(targets)
        self.terminal = terminal
        self.targets = targets
    }

    private static func validate(_ targets: Set<String>) throws {
        guard targets.count <= maxConfiguredTargets,
              targets.allSatisfy({ name in
                  !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                      && ("tmux-reply:" + name).utf8.count <= ReplyLimits.maxIdentifierBytes
                      && !name.contains(where: \.isNewline)
                      && !name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 })
              }) else { throw TmuxReplyAdapterError.invalidConfiguration }
    }

    public func listTargets() async throws -> [AdapterTarget] {
        guard !targets.isEmpty else { return [] }
        return try await terminal.listTargets().filter { targets.contains($0.name) }
    }

    /// There is no legacy fallback: a bridge request without host-owned context must never be delivered.
    public func deliver(_ text: String, to target: String, binding: String?) async throws {
        throw TmuxReplyAdapterError.contextRequired
    }

    public func deliver(
        _ text: String, to target: String, binding: String, context: ProviderTurnContext
    ) async throws {
        try Task.checkCancellation()
        guard targets.contains(target) else { throw AdapterError.unknownTarget(target) }
        guard !binding.isEmpty, context.binding.providerID == kind,
              context.binding.targetID == Registry.id(kind: kind, name: target),
              context.binding.sessionID == binding else { throw ProviderContractError.wrongContext }
        guard !text.isEmpty, text.contains(where: { !$0.isWhitespace }),
              !text.contains(where: \.isNewline), text.utf8.count <= PayloadLimits.maxTextBytes else {
            throw TmuxReplyAdapterError.invalidText
        }
        let envelope = BridgeRequest(version: 1, request: context.id, text: text)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(envelope)
        guard data.count <= PayloadLimits.defaultMaxFrameBytes,
              let line = String(data: data, encoding: .utf8) else { throw TmuxReplyAdapterError.invalidText }
        // TmuxAdapter serializes complete deliveries and rechecks the exact pane binding before Enter.
        try await terminal.deliver(line, to: target, binding: binding)
    }

    public func escape(_ target: String, binding: String?) async throws {
        guard targets.contains(target) else { throw AdapterError.unknownTarget(target) }
        guard let binding, !binding.isEmpty else { throw ProviderContractError.wrongContext }
        try await terminal.escape(target, binding: binding)
    }

    public func capture(_ target: String) async throws -> String {
        throw AdapterError.captureFailed("reply bridge does not support capture")
    }

    private struct BridgeRequest: Encodable {
        let version: Int
        let request: UUID
        let text: String
    }
}
