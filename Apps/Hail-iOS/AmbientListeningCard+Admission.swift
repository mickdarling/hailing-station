import HailCore
import SwiftUI

extension AmbientListeningCard {
    func requestListening(_ on: Bool) {
        #if os(macOS)
        if on {
            guard captureReservation == nil else { return }
            let token = UUID()
            guard exclusion.claim(token) else { return }
            captureReservation = token
            startup = Task {
                guard captureReservation == token else { exclusion.release(token); return }
                let activation = startup
                controller.onRetirementCompleted = {
                    Task {
                        await activation?.value
                        await controller.waitForRetirement()
                        releaseReservation(token)
                    }
                }
                await controller.turnOn(for: binding)
                if !controller.isOn {
                    await controller.waitForRetirement()
                    if captureReservation == token { controller.onRetirementCompleted = nil }
                    releaseReservation(token)
                }
            }
        } else {
            let token = captureReservation, pending = startup
            captureReservation = nil
            startup = nil
            Task {
                await controller.turnOff()
                await pending?.value
                await controller.waitForRetirement()
                releaseReservation(token)
            }
        }
        #else
        Task { on ? await controller.turnOn(for: binding) : await controller.turnOff() }
        #endif
    }

    func updateListening(_ current: AmbientAudioBinding) {
        #if os(macOS)
        let token = captureReservation, pending = startup
        Task {
            await controller.update(binding: current, scene: scene)
            if !controller.isOn {
                await pending?.value
                await controller.waitForRetirement()
                releaseReservation(token)
            }
        }
        #else
        Task { await controller.update(binding: current, scene: scene) }
        #endif
    }

    func closeListening() {
        #if os(macOS)
        let token = captureReservation, pending = startup
        captureReservation = nil
        startup = nil
        Task {
            await controller.destinationLost()
            await pending?.value
            await controller.waitForRetirement()
            releaseReservation(token)
        }
        #else
        Task { await controller.destinationLost() }
        #endif
    }

    #if os(macOS)
    private func releaseReservation(_ token: UUID?) {
        guard let token else { return }
        exclusion.release(token)
        if captureReservation == token { captureReservation = nil }
    }
    #endif
}
