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
            switch try await host.send(text.text, to: target, from: peerName) {
            case .delivered:
                return HostSessionResult(frames: [])
            case .needsConfirmation:
                return failure(.notAllowed, "target requires confirmation at the Mac", close: false, version: version)
            }
        } catch {
            return deliveryFailure(error, version: version)
        }
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
            selectedTarget = targetID
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
