import Foundation
import Testing
@testable import HailCore

@Suite("Mac menu-bar status")
@MainActor
struct StationMenuStatusTests {
    @Test func summaryFollowsWindowConnectionDestinationAndListening() {
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
        _ = status.attachListening(isOn: true) { _ in }
        #expect(status.summary == "Listening · This Mac · build")
    }

    @Test func toggleReachesOnlyTheCurrentControlWhileTheWindowIsOpen() {
        let status = StationMenuStatus()
        var requests: [Bool] = []
        status.setListening(true)
        let token = status.attachListening(isOn: false) { requests.append($0) }
        status.setListening(true) // The window is closed: nothing is asked.
        #expect(requests.isEmpty)
        status.windowOpen = true
        #expect(status.canToggleListening)
        status.setListening(true)
        status.updateListening(true, token: token)
        #expect(requests == [true])
        #expect(status.isListening)
        status.detachListening(token: token)
        #expect(!status.canToggleListening)
        #expect(!status.isListening)
        status.setListening(false)
        #expect(requests == [true])
    }

    @Test func aStaleControlCannotUpdateOrDetachItsSuccessor() {
        let status = StationMenuStatus()
        status.windowOpen = true
        var current: [Bool] = []
        let old = status.attachListening(isOn: false) { _ in Issue.record("the replaced control was asked") }
        let new = status.attachListening(isOn: false) { current.append($0) }
        status.updateListening(true, token: old)
        #expect(!status.isListening)
        status.detachListening(token: old)
        #expect(status.canToggleListening)
        status.setListening(true)
        #expect(current == [true])
        status.detachListening(token: new)
        #expect(!status.canToggleListening)
    }
}
