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

private func words(_ state: PanelState) -> [SetupStep: String] {
  Dictionary(uniqueKeysWithValues: (state.permissions?.rows ?? []).map { ($0.step, $0.word) })
}

private func granted(_ state: PanelState) -> [SetupStep] {
  (state.permissions?.rows ?? []).compactMap {
    if case .granted = $0.grant { $0.step } else { nil }
  }
}

@Test func firstCheckIsWorkingAndOffersNothingYet() {
  let state = PanelState(service: nil, busy: nil, problem: nil, checked: false)
  #expect(state.title == "Checking in…")
  #expect(state.mood == .working)
  #expect(state.primary == .recheck)
  #expect(!state.primaryEnabled)
  #expect(state.permissions == nil)
}

@Test func thePermissionsAreTheMacOSNamesInOrder() throws {
  let rows = try #require(panel(.notRegistered).permissions).rows
  #expect(rows.map(\.step.title) == ["Background activity", "Full Disk Access", "Contacts", "Automation"])
  #expect(rows.allSatisfy { !$0.step.purpose.isEmpty })
}

@Test func aFreshInstallOpensBackgroundActivityAndChecksNothingElse() {
  let state = panel(.notRegistered)
  #expect(state.permissions?.current == .backgroundActivity)
  #expect(words(state) == [
    .backgroundActivity: "Off", .fullDiskAccess: "Not checked", .contacts: "Not checked",
    .automation: "Not checked",
  ])
  #expect(!state.offersConnect)
}

/// Each row: a helper missing that permission, which opens its row, and the
/// words every row shows for it.
@Test func theFirstMissingPermissionIsTheOpenRow() throws {
  let table: [(ServiceState, SetupStep, [SetupStep: String])] = [
    (
      .running(try diagnosis(database: false, contacts: false)), .fullDiskAccess,
      [.backgroundActivity: "On", .fullDiskAccess: "Not allowed", .contacts: "Not allowed", .automation: "Allowed"]
    ),
    (
      .running(try diagnosis(contacts: false)), .contacts,
      [.backgroundActivity: "On", .fullDiskAccess: "Allowed", .contacts: "Not allowed", .automation: "Allowed"]
    ),
    (
      .running(try diagnosis(automation: "permission-gated")), .automation,
      [.backgroundActivity: "On", .fullDiskAccess: "Allowed", .contacts: "Allowed", .automation: "Not allowed"]
    ),
    (
      .running(try diagnosis(automation: "unverified")), .automation,
      [.backgroundActivity: "On", .fullDiskAccess: "Allowed", .contacts: "Allowed", .automation: "Not checked"]
    ),
  ]
  for (service, open, expected) in table {
    let state = panel(service)
    #expect(state.phase == .setup(open), "\(open)")
    #expect(state.permissions?.current == open, "\(open)")
    #expect(words(state) == expected, "\(open)")
    #expect(state.mood == .needsYou)
    #expect(state.primary == nil)
    #expect(!state.offersConnect)
  }
}

@Test func limitedContactsCountAsGranted() throws {
  let state = panel(.running(try diagnosis(contactsStatus: "limited")))
  #expect(words(state)[.contacts] == "Some contacts")
  #expect(state.phase == .ready)
}

@Test func everyPermissionOnIsReady() throws {
  let state = panel(.running(try diagnosis()), facts: SetupFacts(connected: ["Codex"]))
  #expect(state.phase == .ready)
  #expect(state.title == "Ready to help")
  #expect(state.subtitle == "Your assistants can use Messages on this Mac.")
  #expect(state.mood == .ready)
  #expect(state.primary == nil)
  #expect(state.permissions?.current == nil)
  #expect(granted(state) == SetupStep.allCases)
}

@Test func theConnectCardShowsOnlyBetweenTheLastPermissionAndTheFirstAssistant() throws {
  let ready = ServiceState.running(try diagnosis())
  #expect(panel(ready, facts: SetupFacts(connected: [])).offersConnect)
  // Not before the clients are scanned, so it never flashes.
  #expect(!panel(ready, facts: SetupFacts()).offersConnect)
  #expect(!panel(ready, facts: SetupFacts(connected: ["Plug"])).offersConnect)
  #expect(!panel(ready, facts: SetupFacts(connected: [], connectSettled: true)).offersConnect)
  #expect(!panel(.running(try diagnosis(contacts: false)), facts: SetupFacts(connected: [])).offersConnect)
}

@Test func theConnectionsRowNamesWhatIsConnected() throws {
  let ready = ServiceState.running(try diagnosis())
  #expect(panel(ready).connections == nil)
  #expect(panel(ready, facts: SetupFacts(connected: [])).connections == "None")
  #expect(panel(ready, facts: SetupFacts(connected: ["Plug"])).connections == "Plug")
  #expect(panel(ready, facts: SetupFacts(connected: ["Plug", "Codex"])).connections == "Plug and 1 more")
  #expect(panel(.stopped, facts: SetupFacts(connected: ["Plug"])).connections == "Plug")
}

@Test func aRevokedGrantReopensItsRowAndKeepsTheOthers() throws {
  let revoked = panel(.running(try diagnosis(database: false)), facts: SetupFacts(connected: ["Codex"]))
  #expect(revoked.phase == .setup(.fullDiskAccess))
  #expect(revoked.mood == .needsYou)
  #expect(granted(revoked) == [.backgroundActivity, .contacts, .automation])
  let blocked = panel(.blockedInLoginItems)
  #expect(blocked.phase == .blocked)
  #expect(blocked.step == .backgroundActivity)
  #expect(blocked.permissions?.current == .backgroundActivity)
}

@Test func noHeadlineNamesARetiredStep() throws {
  let states = [
    panel(.notRegistered), panel(.blockedInLoginItems),
    panel(.running(try diagnosis(database: false))), panel(.running(try diagnosis(contacts: false))),
    panel(.running(try diagnosis(automation: "unverified"))), panel(.running(try diagnosis())),
  ]
  for state in states {
    for retired in ["Allow in the background", "Read messages", "Show names", "Send messages", "Try it", "names"] {
      #expect(!state.title.contains(retired), "\(state.phase)")
    }
  }
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
  #expect(state.step == .backgroundActivity)
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
    #expect(state.permissions == nil, "\(service)")
  }
}

@Test func onlyAnUnfinishedSetupNoticeIsNeutral() {
  #expect(Notice.setupUnfinished.tone == .neutral)
  for notice in [Notice.resting, .connected, .tried, .granted(.contacts), .granted(.automation)] {
    #expect(notice.tone == .good)
  }
}
