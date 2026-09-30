import Foundation
import HailProtocol

extension HostSession {
    func route(_ frame: Frame, version: Int) async -> HostSessionResult {
        switch frame.payload {
        case .text(let text):
            return await deliver(text, frame: frame, version: version)
        case .control(let control):
            return await route(control, version: version)
        default:
            return failure(.unauthorized, "terminal action is not authorized", close: false, version: version)
        }
    }

    private func deliver(_ text: TextPayload, frame: Frame, version: Int) async -> HostSessionResult {
        guard text.isFinal else {
            return failure(.malformed, "only final text can be delivered", close: false, version: version)
        }
        guard let target = frame.target, target == selectedTarget else {
            return failure(.notAllowed, "select the destination before speaking", close: false, version: version)
        }
        do {
            let generation = selectionGeneration
            let context = try await replyContext(target: target, utteranceID: frame.id, generation: generation)
            let outcome = try await send(text.text, target: target, context: context)
            switch outcome {
            case .delivered:
                if let context {
                    guard generation == selectionGeneration, var request = replyRequests[context.id] else {
                        return failure(.notAllowed, "request destination changed", close: false, version: version)
                    }
                    request.committed = true
                    guard request.withAuthority({
                        guard request.isCurrent(at: requestClock()) else { return false }
                        replyRequests[context.id] = request
                        return true
                    }) == true else {
                        replyRequests[context.id] = nil
                        return failure(.notAllowed, "reply authority changed", close: false, version: version)
                    }
                }
                return HostSessionResult(frames: [])
            case .needsConfirmation:
                if let context { replyRequests[context.id] = nil }
                return failure(.notAllowed, "target requires confirmation at the Mac", close: false, version: version)
            }
        } catch {
            return deliveryFailure(error, version: version)
        }
    }

    private func send(_ text: String, target: String, context: ProviderTurnContext?) async throws -> SendOutcome {
        do {
            if let context { return try await host.send(text, context: context, from: peerName) }
            return try await host.send(text, to: target, from: peerName)
        } catch {
            if let context { replyRequests[context.id] = nil }
            throw error
        }
    }

    /// Capability preflight does not grant execution. HailHost still checks shape, exact binding and policy.
    private func replyContext(
        target: String, utteranceID: UUID, generation: UUID
    ) async throws -> ProviderTurnContext? {
        let listing = try await host.registry.listing()
        guard let listed = listing.first(where: { $0.info.id == target }), let binding = listed.binding,
              listed.info.alive else { throw HostError.unknownTarget(target) }
        let context = ProviderTurnContext(utteranceID: utteranceID, connectionID: connectionID, binding: try .init(
            hostID: hostName, providerID: listed.info.kind, targetID: target, sessionID: binding
        ))
        do {
            try await host.registry.requireInputDelivery(to: target, context: context, lineCount: 1)
        } catch RegistryError.contextualDeliveryUnsupported {
            // Legacy generic input is unchanged; it cannot establish a private reply recipient.
            return nil
        }
        // Listings are snapshots, not leases. Contextual adapters without cooperative binding authority
        // refuse before dispatch; they must not masquerade as safe private reply bridges.
        let lease = try await host.registry.acquireReplyBindingLease(context.binding)
        guard let permit = await host.replyPublicationPermit(for: context.binding) else {
            throw HostError.denied(.notAllowed(target))
        }
        pruneReplyRequests()
        guard case .ready = state, generation == selectionGeneration, selectedTarget == target,
              replyRequests.count < HostReplyRequest.capacity else { throw ProviderContractError.capacityExceeded }
        replyRequests[context.id] = HostReplyRequest(
            context: context, generation: generation, createdAt: requestClock(),
            policyPermit: permit, bindingLease: lease
        )
        return context
    }

    private func route(_ control: ControlPayload, version: Int) async -> HostSessionResult {
        switch control {
        case .ping(let nonce):
            return HostSessionResult(frames: [response(.pong(nonce: nonce), version: version)])
        case .listTargets:
            return await listTargets(version: version)
        case .select(let targetID):
            return await select(targetID, version: version)
        case .escape(let targetID):
            return await escape(targetID, version: version)
        case .hello:
            return failure(.malformed, "hello already received", close: true, version: version)
        default:
            return failure(.unauthorized, "connection probe is read-only", close: false, version: version)
        }
    }

    private func listTargets(version: Int) async -> HostSessionResult {
        do {
            return HostSessionResult(frames: [response(.targets(try await policyFilteredTargets()), version: version)])
        } catch {
            return failure(.malformed, "target listing unavailable", close: false, version: version)
        }
    }

    private func select(_ targetID: String, version: Int) async -> HostSessionResult {
        do {
            guard try await policyFilteredTargets().contains(where: { $0.id == targetID && $0.alive }) else {
                return failure(.notAllowed, "target is unavailable or not allowed", close: false, version: version)
            }
            if selectedTarget != targetID {
                selectionGeneration = UUID()
                replyRequests.removeAll()
                selectedTarget = targetID
            }
            return HostSessionResult(frames: [])
        } catch {
            return failure(.malformed, "target selection unavailable", close: false, version: version)
        }
    }

    private func escape(_ targetID: String, version: Int) async -> HostSessionResult {
        guard targetID == selectedTarget else {
            return failure(.notAllowed, "select the destination before sending Escape", close: false, version: version)
        }
        do {
            try await host.escape(targetID)
            return HostSessionResult(frames: [])
        } catch {
            return deliveryFailure(error, version: version)
        }
    }

    private func deliveryFailure(_ error: any Error, version: Int) -> HostSessionResult {
        let code: ErrorCode
        switch error {
        case HostError.unknownTarget: code = .unknownTarget
        case HostError.denied(.lockdown): code = .lockdown
        case is HostError, is AdapterError, is RegistryError: code = .notAllowed
        default: code = .malformed
        }
        return failure(code, "target action was refused", close: false, version: version)
    }

    private func policyFilteredTargets() async throws -> [TargetInfo] {
        let listing = try await host.registry.listing()
        guard await host.policyFailure == nil else { return [] }
        let policy = await host.currentPolicy
        return listing.compactMap { listed in
            guard let allowed = policy.targets[listed.info.id], allowed.binding == listed.binding else { return nil }
            return listed.info
        }
    }
}
