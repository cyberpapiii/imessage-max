import Foundation
import IMessageMaxContract
import MaxBrand
import MaxCore
import Testing
import MaxTestSupport

@testable import iMessageMaxMenu

private func panel(_ service: ServiceState?, busy: Busy? = nil, problem: String? = nil)
  -> PanelState
{
  PanelState(service: service, busy: busy, problem: problem, checked: true)
}

@Test func firstCheckIsWorkingAndOffersNothingYet() {
  let state = PanelState(service: nil, busy: nil, problem: nil, checked: false)
  #expect(state.title == "Checking in…")
  #expect(state.mood == .working)
  #expect(state.primary == .recheck)
  #expect(!state.primaryEnabled)
}

@Test func readyServiceOffersTheConnectionPage() throws {
  let state = panel(.running(try diagnosis()))
  #expect(state.title == "Ready to help")
  #expect(state.primary == .connect)
  #expect(state.mood == .ready)
}

@Test func aWaitingSetupStepHidesThePrimaryButton() throws {
  let state = panel(.running(try diagnosis(contacts: false)))
  #expect(state.title == "Let’s add names")
  #expect(state.primary == nil)
  #expect(state.mood == .needsYou)
}

@Test func busyOverridesTheHeadlineButKeepsTheButtonsPlace() {
  let state = panel(.stopped, busy: .starting)
  #expect(state.title == "Getting ready…")
  #expect(state.primaryTitle == "Working…")
  #expect(state.primary == .start)
  #expect(!state.primaryEnabled)
}

@Test func aProblemTroublesTheFaceNotTheHeadline() {
  let state = panel(.notRegistered, problem: "x")
  #expect(state.title == "Hello, iMessage Max")
  #expect(state.primaryTitle == "Set up iMessage Max")
  #expect(state.mood == .trouble)
}

@Test func eachBlockedStateOffersTheOneStepThatClearsIt() {
  let table: [(ServiceState, PanelState.Primary, String)] = [
    (.misplaced(translocated: true), .move, "Move to Applications"),
    (.misplaced(translocated: false), .move, "Move to Applications"),
    (.legacyInstall, .migrate, "Replace the older helper"),
    (.blockedInLoginItems, .openLoginItems, "Open Login Items"),
    (.notRegistered, .start, "Set up iMessage Max"),
    (.stopped, .start, "Start iMessage Max"),
    (.portConflict, .recheck, "Check again"),
    (.unresponsive, .recheck, "Check again"),
    (.tokenRejected, .restart, "Restart iMessage Max"),
  ]
  for (service, primary, title) in table {
    let state = panel(service)
    #expect(state.primary == primary, "\(service)")
    #expect(state.primaryTitle == title, "\(service)")
  }
}

@Test func onlyAnUnfinishedSetupNoticeIsNeutral() {
  #expect(Notice.setupUnfinished.tone == .neutral)
  for notice in [Notice.resting, .connected, .granted(.contacts), .granted(.automation)] {
    #expect(notice.tone == .good)
  }
}
