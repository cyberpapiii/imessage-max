import Foundation
import IMessageMaxContract
import MaxBrand
import MaxCore
import Testing
import MaxTestSupport

@testable import iMessageMaxMenu

private func panel(
  _ service: ServiceState?, facts: SetupFacts = SetupFacts(), busy: Busy? = nil,
  problem: String? = nil
) -> PanelState {
  PanelState(service: service, facts: facts, busy: busy, problem: problem, checked: true)
}

private func progress(_ state: PanelState) -> [SetupStep: StepProgress] {
  Dictionary(uniqueKeysWithValues: (state.firstRun?.rows ?? []).map { ($0.step, $0.progress) })
}

@Test func firstCheckIsWorkingAndOffersNothingYet() {
  let state = PanelState(service: nil, busy: nil, problem: nil, checked: false)
  #expect(state.title == "Checking in…")
  #expect(state.mood == .working)
  #expect(state.primary == .recheck)
  #expect(!state.primaryEnabled)
  #expect(state.firstRun == nil)
}

@Test func theStepsAreTheContractsStepsInOrder() throws {
  let rows = try #require(panel(.notRegistered).firstRun).rows
  #expect(rows.map(\.step) == SetupStep.allCases)
  #expect(rows.map(\.step.title) == [
    "Allow in the background", "Read messages", "Show names", "Send messages",
    "Connect an assistant", "Try it",
  ])
}

/// Each row: the state that leaves the step unfinished, the state that passes
/// its done check, and the facts both are judged with.
@Test func eachStepIsCurrentUntilItsDoneCheckPasses() throws {
  let table: [(SetupStep, ServiceState, ServiceState, SetupFacts)] = [
    (.allowInBackground, .notRegistered, .running(try diagnosis(database: false)), SetupFacts()),
    (
      .readMessages, .running(try diagnosis(database: false)),
      .running(try diagnosis(contacts: false)), SetupFacts()
    ),
    (
      .showNames, .running(try diagnosis(contacts: false)),
      .running(try diagnosis(automation: "unverified")), SetupFacts()
    ),
    (
      .sendMessages, .running(try diagnosis(automation: "permission-gated")),
      .running(try diagnosis()), SetupFacts()
    ),
    (
      .connectAssistant, .running(try diagnosis()), .running(try diagnosis()),
      SetupFacts(connected: ["Codex"])
    ),
    (
      .tryIt, .running(try diagnosis()), .running(try diagnosis()),
      SetupFacts(connected: ["Codex"], tried: true)
    ),
  ]
  for (index, (step, unfinished, finished, facts)) in table.enumerated() {
    let before = facts.tried ? SetupFacts(connected: facts.connected) : SetupFacts()
    let waiting = panel(unfinished, facts: before)
    #expect(waiting.step == step, "\(step)")
    #expect(progress(waiting)[step] == .current, "\(step)")
    let next = panel(finished, facts: facts)
    if case .done = progress(next)[step] {} else { Issue.record("\(step) not done: \(next.phase)") }
    #expect(next.step == table.dropFirst(index + 1).first?.0, "after \(step)")
  }
}

@Test func doneRowsNameWhatTheyFound() throws {
  let limited = panel(.running(try diagnosis(contactsStatus: "limited")))
  #expect(progress(limited)[.showNames] == .done("Some names"))
  let two = panel(.running(try diagnosis()), facts: SetupFacts(connected: ["Codex", "Plug"]))
  #expect(progress(two)[.connectAssistant] == .done("Codex and 1 more"))
  let used = panel(.running(try diagnosis()), facts: SetupFacts(tried: true))
  #expect(progress(used)[.connectAssistant] == .done("Connected"))
  #expect(progress(used)[.tryIt] == .done("Worked"))
  #expect(progress(used)[.allowInBackground] == .done("On"))
}

@Test func finishingEveryStepIsReady() throws {
  let state = panel(.running(try diagnosis()), facts: SetupFacts(connected: ["Codex"], tried: true))
  #expect(state.phase == .ready)
  #expect(state.title == "Ready to help")
  #expect(state.mood == .ready)
  #expect(state.primary == nil)
  #expect(state.firstRun?.rows.allSatisfy { if case .done = $0.progress { true } else { false } } == true)
}

@Test func skippingConnectStillReachesReadyAndKeepsTheStepInTheList() throws {
  let skipped = panel(.running(try diagnosis()), facts: SetupFacts(skippedConnect: true))
  #expect(skipped.step == .tryIt)
  #expect(skipped.title == "Ready to help")
  #expect(skipped.mood == .ready)
  #expect(progress(skipped)[.connectAssistant] == .skipped)
  let used = panel(.running(try diagnosis()), facts: SetupFacts(skippedConnect: true, tried: true))
  #expect(used.phase == .ready)
  #expect(progress(used)[.connectAssistant] == .done("Connected"))
}

@Test func aRevokedGrantSendsTheListBackToItsStep() throws {
  let facts = SetupFacts(connected: ["Codex"], tried: true)
  let revoked = panel(.running(try diagnosis(database: false)), facts: facts)
  #expect(revoked.phase == .setup(.readMessages))
  #expect(revoked.mood == .needsYou)
  #expect(progress(revoked)[.readMessages] == .current)
  for step in [SetupStep.showNames, .sendMessages, .connectAssistant, .tryIt] {
    if case .done = progress(revoked)[step] {} else { Issue.record("\(step) lost its state") }
  }
  let blocked = panel(.blockedInLoginItems, facts: facts)
  #expect(blocked.phase == .blocked)
  #expect(blocked.step == .allowInBackground)
}

@Test func onlyTheGrantStepsNeedTheUser() throws {
  #expect(panel(.notRegistered).needsGrant)
  #expect(panel(.running(try diagnosis(contacts: false))).needsGrant)
  #expect(!panel(.running(try diagnosis())).needsGrant)
  #expect(!panel(.running(try diagnosis()), facts: SetupFacts(tried: true)).needsGrant)
  #expect(!panel(.stopped).needsGrant)
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
  #expect(state.step == .allowInBackground)
  #expect(state.mood == .trouble)
}

@Test func eachBlockedStateOffersTheOneStepThatClearsIt() {
  let table: [(ServiceState, PanelState.Primary, String)] = [
    (.misplaced(translocated: true), .move, "Move to Applications"),
    (.misplaced(translocated: false), .move, "Move to Applications"),
    (.legacyInstall, .migrate, "Replace the older helper"),
    (.stopped, .start, "Start iMessage Max"),
    (.portConflict, .recheck, "Check again"),
    (.unresponsive, .recheck, "Check again"),
    (.tokenRejected, .restart, "Restart iMessage Max"),
  ]
  for (service, primary, title) in table {
    let state = panel(service)
    #expect(state.primary == primary, "\(service)")
    #expect(state.primaryTitle == title, "\(service)")
    #expect(state.firstRun == nil, "\(service)")
  }
}

@Test func onlyAnUnfinishedSetupNoticeIsNeutral() {
  #expect(Notice.setupUnfinished.tone == .neutral)
  for notice in [Notice.resting, .connected, .tried, .granted(.contacts), .granted(.automation)] {
    #expect(notice.tone == .good)
  }
}
