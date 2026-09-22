actor FakeAudioLifecycleSuspension {
    private var holdConfiguration = false
    private var heldConfiguration: CheckedContinuation<Void, Never>?
    private var holdActivation = false
    private var heldActivation: CheckedContinuation<Void, Never>?

    func suspendConfigurationIfNeeded() async {
        guard holdConfiguration else { return }
        holdConfiguration = false
        await withCheckedContinuation { continuation in
            heldConfiguration = continuation
        }
    }

    func suspendActivationIfNeeded() async {
        guard holdActivation else { return }
        holdActivation = false
        await withCheckedContinuation { continuation in
            heldActivation = continuation
        }
    }

    func holdNextConfiguration() { holdConfiguration = true }

    func waitUntilConfigurationIsHeld() async {
        while heldConfiguration == nil { await Task.yield() }
    }

    func releaseConfiguration() {
        let continuation = heldConfiguration
        heldConfiguration = nil
        continuation?.resume()
    }

    func holdNextActivation() { holdActivation = true }

    func waitUntilActivationIsHeld() async {
        while heldActivation == nil { await Task.yield() }
    }

    func releaseActivation() {
        let continuation = heldActivation
        heldActivation = nil
        continuation?.resume()
    }
}

extension FakeAudioSessionBackend {
    func holdNextConfigureCall() async {
        await lifecycleSuspension.holdNextConfiguration()
    }

    func waitUntilConfigurationIsHeld() async {
        await lifecycleSuspension.waitUntilConfigurationIsHeld()
    }

    func releaseHeldConfiguration() async {
        await lifecycleSuspension.releaseConfiguration()
    }

    func holdNextActivationCall() async {
        await lifecycleSuspension.holdNextActivation()
    }

    func waitUntilActivationIsHeld() async {
        await lifecycleSuspension.waitUntilActivationIsHeld()
    }

    func releaseHeldActivation() async {
        await lifecycleSuspension.releaseActivation()
    }
}
