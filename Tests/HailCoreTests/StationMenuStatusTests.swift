import Foundation
import Testing
@testable import HailCore

@Suite("Mac menu-bar status")
@MainActor
struct StationMenuStatusTests {
    @Test func summaryFollowsWindowConnectionAndDestination() {
        let status = StationMenuStatus()
        #expect(status.summary == "Station window closed")
        status.windowOpen = true
        #expect(status.summary == "No Mac set up")
        status.hostCount = 1
        #expect(status.summary == "Not connected")
        status.readyHostCount = 1
        #expect(status.summary == "Connected · choose a destination")
        status.destination = "This Mac · build"
        #expect(status.summary == "Ready · This Mac · build")
    }

    @Test func listeningPhasesAreNamedAsTheCardShowsThem() {
        let status = StationMenuStatus()
        status.windowOpen = true
        status.hostCount = 1
        status.readyHostCount = 1
        status.destination = "This Mac · build"
        let token = status.attachListening(.starting) { _ in }
        #expect(status.summary == "Starting to listen · This Mac · build")
        status.updateListening(.listening, token: token)
        #expect(status.summary == "Listening · This Mac · build")
        status.updateListening(.paused, token: token)
        #expect(status.summary == "Listening paused: another app has the mic · This Mac · build")
        #expect(status.listening.isOn)
        status.updateListening(.elsewhere, token: token)
        #expect(status.summary == "Listening on another device · This Mac · build")
        #expect(!status.listening.isOn)
    }

    @Test func toggleReachesOnlyTheCurrentControlWhileTheWindowIsOpen() {
        let status = StationMenuStatus()
        var requests: [Bool] = []
        status.setListening(true)
        let token = status.attachListening(.off) { requests.append($0) }
        status.setListening(true) // The window is closed: nothing is asked.
        #expect(requests.isEmpty)
        status.windowOpen = true
        #expect(status.canToggleListening)
        status.setListening(true)
        status.updateListening(.listening, token: token)
        #expect(requests == [true])
        #expect(status.listening == .listening)
        status.detachListening(token: token)
        #expect(!status.canToggleListening)
        #expect(status.listening == .off)
        status.setListening(false)
        #expect(requests == [true])
    }

    @Test func aStaleControlCannotUpdateOrDetachItsSuccessor() {
        let status = StationMenuStatus()
        status.windowOpen = true
        var current: [Bool] = []
        let old = status.attachListening(.off) { _ in Issue.record("the replaced control was asked") }
        let new = status.attachListening(.off) { current.append($0) }
        status.updateListening(.listening, token: old)
        #expect(status.listening == .off)
        status.detachListening(token: old)
        #expect(status.canToggleListening)
        status.setListening(true)
        #expect(current == [true])
        status.detachListening(token: new)
        #expect(!status.canToggleListening)
    }
}
