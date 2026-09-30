import Foundation
import Testing
@testable import HailDaemonKit

/// A deterministic write refusal layered over actual scratch-file load/validation, never live config.
private struct PublicationSaveFailingPolicyFile: PolicyStore {
    let file: PolicyFile
    let failure = PolicyFileError.unwritable("synthetic write failure")
    var summary: String { "synthetic scratch policy" }
    func load() throws -> Policy { try file.load() }
    func update(_ change: (inout Policy) throws -> Void) throws -> PolicyUpdate {
        var policy = try file.load()
        try change(&policy)
        throw failure
    }
}

@Suite struct ReplyPublicationPolicyFileTests {
    private let target = "tmux:synthetic"
    private let sessionID = "synthetic-binding"
    private let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("hailing-publication-policy-\(UUID().uuidString)", isDirectory: true)
    private var file: PolicyFile { PolicyFile(directory: scratch) }

    private func makeHost(store: any PolicyStore) async throws -> (HailHost, ProviderSessionBinding) {
        let registry = Registry()
        try await registry.register(FakeAdapter(
            kind: "tmux", targets: [AdapterTarget(name: "synthetic", binding: sessionID)]
        ))
        let binding = try ProviderSessionBinding(
            hostID: "synthetic-host", providerID: "tmux", targetID: target, sessionID: sessionID
        )
        return (try HailHost(registry: registry, store: store), binding)
    }

    private func initialPolicy() throws -> Policy {
        var policy = Policy()
        try policy.allow(target, binding: sessionID, tier: .open)
        return policy
    }

    @Test(arguments: [false, true])
    func failedTransactionRevalidatesMalformedOrUntrustedDiskPolicy(wrongPermissions: Bool) async throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        try file.save(initialPolicy())
        let (host, binding) = try await makeHost(store: file)
        let permit = try #require(await host.replyPublicationPermit(for: binding))
        if wrongPermissions {
            try #require(chmod(file.path.path, 0o644) == 0)
        } else {
            try Data("synthetic malformed policy".utf8).write(to: file.path)
        }
        // The original PolicyFile diagnostic is preserved, not replaced with HostError.
        await #expect(throws: PolicyFileError.self) { try await host.deny(target) }
        #expect(permit.performIfCurrent { true } == nil)
        #expect(await host.policyFailure != nil)
        #expect(await host.replyPublicationPermit(for: binding) == nil)
    }

    @Test(arguments: [false, true])
    func failedSaveReconcilesActualChangedDiskPolicy(rebound: Bool) async throws {
        defer { try? FileManager.default.removeItem(at: scratch) }
        try file.save(initialPolicy())
        let store = PublicationSaveFailingPolicyFile(file: file)
        let (host, binding) = try await makeHost(store: store)
        let permit = try #require(await host.replyPublicationPermit(for: binding))
        var external = Policy()
        if rebound { try external.allow(target, binding: "replacement-binding", tier: .open) }
        try file.save(external)
        await #expect(throws: store.failure) { try await host.allow(target, tier: .open) }
        #expect(permit.performIfCurrent { true } == nil)
        #expect(await host.currentPolicy == external)
        #expect(await host.policyFailure == nil)
        #expect(await host.replyPublicationPermit(for: binding) == nil)
    }
}
