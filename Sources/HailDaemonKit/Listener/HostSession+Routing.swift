import Foundation
import HailProtocol

// The phone frame and local dispatch ingress paths share one handoff-and-commit boundary here.
// swiftlint:disable file_length

/// Both ingress paths share one lease, permit, handoff and commit; they differ only in how they report it.
enum HostDeliveryOutcome: Sendable, Equatable {
    /// Handed off; `request` is this connection's committed reply owner, or nil for legacy generic input.
    case delivered(request: UUID?)
    case confirmationRequired
    /// The connection selected another target while this input was suspended; nothing was handed off.
    case selectionChanged
    /// The target may have received the text, but no reply ownership survived the handoff.
    case unowned(String)
    case refused(ErrorCode, String)
}

extension HostSession {
    func route(_ admitted: AdmittedFrame, version: Int) async -> HostSessionResult {
        switch admitted {
        case .input(let input):
            return await deliver(input, version: version)
        case .control(let control):
            return await route(control, version: version)
        case .nonFinalText:
            return failure(.malformed, "only final text can be delivered", close: false, version: version)
        case .untargetedText:
            return failure(.notAllowed, "select the destination before speaking", close: false, version: version)
        case .unsupported:
            return failure(.unauthorized, "terminal action is not authorized", close: false, version: version)
        }
    }

    private func deliver(_ input: AuthorizedInput, version: Int) async -> HostSessionResult {
        switch await deliver(input) {
        case .delivered:
            return HostSessionResult(frames: [])
        case .confirmationRequired:
            return failure(.notAllowed, "target requires confirmation at the Mac", close: false, version: version)
        case .selectionChanged:
            return failure(.notAllowed, "request destination changed", close: false, version: version)
        case .unowned(let message):
            return failure(.notAllowed, message, close: false, version: version)
        case .refused(let code, let message):
            return failure(code, message, close: false, version: version)
        }
    }

    /// Lease, permit, capacity, lifetime and generation checks, then `HailHost.send` with its sanitizer,
    /// shape and policy gates; only a successful complete handoff commits the request record. The input
    /// type is the authorization proof: nothing reaches the host that the session's authorizer did not allow.
    func deliver(_ input: AuthorizedInput) async -> HostDeliveryOutcome {
        guard input.target == selectedTarget else {
            return .refused(.notAllowed, "select the destination before speaking")
        }
        do {
            let generation = selectionGeneration
            let context = try await replyContext(for: input, generation: generation)
            // Legacy generic input has no retained record, so the captured selection is checked here and
            // again after the handoff; a caller outside the peer's serialized receive loop can race `select`.
            guard selects(input.target, generation: generation) else {
                if let context { replyRequests[context.id] = nil }
                return .selectionChanged
            }
            switch try await send(input, context: context) {
            case .delivered:
                guard let context else {
                    guard selects(input.target, generation: generation) else {
                        return .unowned("request destination changed")
                    }
                    return .delivered(request: nil)
                }
                return commit(context, generation: generation)
            case .needsConfirmation:
                if let context { replyRequests[context.id] = nil }
                return .confirmationRequired
            }
        } catch {
            return .refused(deliveryCode(error), "target action was refused")
        }
    }

    /// The captured selection authority: still negotiated, same selection generation, same target.
    private func selects(_ target: String, generation: UUID) -> Bool {
        guard case .ready = state else { return false }
        return generation == selectionGeneration && selectedTarget == target
    }

    private func commit(_ context: ProviderTurnContext, generation: UUID) -> HostDeliveryOutcome {
        guard selects(context.binding.targetID, generation: generation), var request = replyRequests[context.id] else {
            return .unowned("request destination changed")
        }
        request.committed = true
        guard request.withAuthority({
            guard request.isCurrent(at: requestClock()) else { return false }
            replyRequests[context.id] = request
            return true
        }) == true else {
            replyRequests[context.id] = nil
            return .unowned("reply authority changed")
        }
        return .delivered(request: context.id)
    }

    private func send(_ input: AuthorizedInput, context: ProviderTurnContext?) async throws -> SendOutcome {
        do {
            if let context { return try await host.send(input.text, context: context, from: input.device) }
            return try await host.send(
                input.text, to: input.target, from: input.device, expectedBinding: input.expectedBinding
            )
        } catch {
            if let context { replyRequests[context.id] = nil }
            throw error
        }
    }

    /// Capability preflight does not grant execution. HailHost still checks shape, exact binding and policy.
    private func replyContext(for input: AuthorizedInput, generation: UUID) async throws -> ProviderTurnContext? {
        let target = input.target
        let listing = try await host.registry.listing()
        guard let listed = listing.first(where: { $0.info.id == target }), let binding = listed.binding,
              listed.info.alive else { throw HostError.unknownTarget(target) }
        if let expected = input.expectedBinding, expected != binding { throw HostError.denied(.rebound(target)) }
        let context = ProviderTurnContext(
            utteranceID: input.utteranceID, connectionID: connectionID,
            binding: try .init(hostID: hostName, providerID: listed.info.kind, targetID: target, sessionID: binding)
        )
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
        guard case .ready = state, generation == selectionGeneration, selectedTarget == target else {
            throw HostError.denied(.notAllowed(target))
        }
        guard replyRequests.count < HostReplyRequest.capacity else { throw ProviderContractError.capacityExceeded }
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
        failure(deliveryCode(error), "target action was refused", close: false, version: version)
    }

    private func deliveryCode(_ error: any Error) -> ErrorCode {
        switch error {
        case HostError.unknownTarget: .unknownTarget
        case HostError.denied(.lockdown): .lockdown
        case ProviderContractError.capacityExceeded: .rateLimited
        case is HostError, is AdapterError, is RegistryError: .notAllowed
        default: .malformed
        }
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
