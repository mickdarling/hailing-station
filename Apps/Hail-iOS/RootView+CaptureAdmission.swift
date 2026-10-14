import HailCore
import SwiftUI

extension RootView {
    var captureMayBegin: @MainActor () -> Bool {
        #if os(macOS)
        let exclusion = captureExclusion
        let coaching = coachingController
        return { !exclusion.isClaimed && coaching.state == .off }
        #else
        return { true }
        #endif
    }

    func captureRequested(_ token: UUID) {
        #if os(macOS)
        captureExclusion.claim(token)
        #endif
    }

    func captureReleased(_ token: UUID) {
        #if os(macOS)
        captureExclusion.release(token)
        #endif
    }
}
