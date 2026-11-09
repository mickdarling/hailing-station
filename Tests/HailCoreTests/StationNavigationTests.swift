import Testing
@testable import HailCore

@Suite("Station navigation (#1115)")
struct StationNavigationTests {
    @Test func defaultsOpenOnTheStationWithTheInspectorClosed() {
        let state = StationNavigationState()
        #expect(state.section == .station)
        #expect(!state.inspectorPresented)
        #expect(!state.showsInspector)
        #expect(!state.fullConversation)
    }

    @Test func layoutFollowsTheIdiomNotTheWidth() {
        let state = StationNavigationState()
        #expect(state.layout(for: .phone) == .tabs(tabBarVisible: true))
        #expect(state.layout(for: .pad) == .split(sidebarVisible: true))
        #expect(state.layout(for: .mac) == .split(sidebarVisible: true))
    }

    @Test func everyIdiomListsTheSameFourSectionsWithNoCoaching() {
        #expect(StationSection.allCases == [.station, .sessions, .devices, .settings])
        #expect(Set(StationSection.allCases.map(\.title)).count == 4)
        #expect(Set(StationSection.allCases.map(\.systemImage)).count == 4)
    }

    @Test func fullConversationHidesNavigationAndTheInspectorButRemembersIt() {
        var state = StationNavigationState()
        state.apply(.toggleInspector)
        #expect(state.showsInspector)
        state.apply(.toggleFullConversation)
        #expect(state.fullConversation)
        #expect(state.layout(for: .phone) == .tabs(tabBarVisible: false))
        #expect(state.layout(for: .pad) == .split(sidebarVisible: false))
        #expect(!state.showsInspector)
        #expect(state.inspectorPresented)
        state.apply(.toggleFullConversation)
        #expect(state.showsInspector)
    }

    @Test func fullConversationAppliesOnlyToTheStation() {
        var state = StationNavigationState(section: .settings)
        state.apply(.toggleFullConversation)
        #expect(!state.fullConversation)
        #expect(!StationNavigationState(section: .devices, fullConversation: true).fullConversation)
    }

    @Test func leavingTheStationLeavesFullConversationSoTheWayBackShows() {
        var state = StationNavigationState(fullConversation: true)
        state.apply(.select(.sessions))
        #expect(state.section == .sessions)
        #expect(!state.fullConversation)
        #expect(state.layout(for: .phone) == .tabs(tabBarVisible: true))
    }

    @Test func reselectingTheStationKeepsFullConversation() {
        var state = StationNavigationState(fullConversation: true)
        state.apply(.select(.station))
        #expect(state.fullConversation)
    }

    @Test func openingTheInspectorOrSidebarLeavesFullConversation() {
        var inspector = StationNavigationState(fullConversation: true)
        inspector.apply(.toggleInspector)
        #expect(!inspector.fullConversation)
        #expect(inspector.showsInspector)

        var sidebar = StationNavigationState(fullConversation: true)
        sidebar.apply(.setSidebarHidden(false))
        #expect(!sidebar.fullConversation)
        #expect(sidebar.layout(for: .mac) == .split(sidebarVisible: true))
    }

    @Test func hidingTheSidebarIsSplitOnlyAndKeepsFullConversation() {
        var state = StationNavigationState()
        state.apply(.setSidebarHidden(true))
        #expect(state.layout(for: .mac) == .split(sidebarVisible: false))
        #expect(state.layout(for: .phone) == .tabs(tabBarVisible: true))
        state.apply(.toggleFullConversation)
        state.apply(.setSidebarHidden(true))
        #expect(state.fullConversation)
    }

    @Test func aCollapsedSplitOpensOnTheStationDetail() {
        let state = StationNavigationState()
        #expect(state.compactColumn == .detail)
        #expect(state.sidebarSelection(collapsed: true) == .station)
    }

    // Codex review of #1148: in a collapsed iPad split view, choosing a section must navigate to its detail.
    @Test func selectingFromACollapsedSidebarNavigatesToTheDetail() {
        var state = StationNavigationState()
        state.apply(.setCompactColumn(.sidebar))
        state.apply(.select(.devices))
        #expect(state.section == .devices)
        #expect(state.compactColumn == .detail)
    }

    @Test func aCollapsedSidebarHighlightsNothingSoTheCurrentSectionCanBeReopened() {
        var state = StationNavigationState()
        state.apply(.setCompactColumn(.sidebar))
        #expect(state.sidebarSelection(collapsed: true) == nil)
        // An expanded split view always shows the current section.
        #expect(state.sidebarSelection(collapsed: false) == .station)
        state.apply(.select(.station))
        #expect(state.compactColumn == .detail)
        #expect(state.sidebarSelection(collapsed: true) == .station)
    }
}
