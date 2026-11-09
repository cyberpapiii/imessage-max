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

@Suite struct PanelStateTests {
  @Test func firstCheckIsWorkingAndOffersNothingYet() {
    let state = PanelState(service: nil, busy: nil, problem: nil, checked: false)
    #expect(state.status == .working("Checking…"))
    #expect(state.attention == nil)
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
    #expect(state.status == .running)
    #expect(state.attention == nil)
    #expect(state.subtitle == "Your assistants can use Messages on this Mac.")
    #expect(state.mood == .ready)
    #expect(state.primary == nil)
    #expect(state.permissions?.current == nil)
    #expect(granted(state) == SetupStep.allCases)
  }

  @Test func theConnectPromptShowsOnlyBetweenTheLastPermissionAndTheFirstAssistant() throws {
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

  @Test func busyNamesWhatIsHappeningAndHoldsTheButton() {
    let state = panel(.stopped, busy: .starting)
    #expect(state.status == .working("Getting ready…"))
    #expect(state.attention == nil)
    #expect(state.primary == .start)
    #expect(!state.primaryEnabled)
  }

  @Test func aProblemTroublesTheFaceNotTheStep() {
    let state = panel(.notRegistered, problem: "x")
    #expect(state.status == .settingUp)
    #expect(state.step == .backgroundActivity)
    #expect(state.mood == .trouble)
  }

  @Test func aProblemWhileRunningNeedsAttentionOnGeneral() throws {
    let state = panel(.running(try diagnosis()), facts: SetupFacts(connected: ["Plug"]), problem: "x")
    #expect(state.status == .attention)
    #expect(state.attention?.page == .general)
  }

  /// Each row: a state that blocks the helper, the button that clears it, and
  /// the page the status menu sends the user to.
  @Test func eachBlockedStateOffersTheOneStepThatClearsIt() {
    let table: [(ServiceState, PanelState.Primary, String, SettingsPage?)] = [
      (.misplaced(translocated: true), .move, "Move to Applications", .general),
      (.misplaced(translocated: false), .move, "Move to Applications", .general),
      (.legacyInstall, .migrate, "Replace Older Helper", .general),
      (.stopped, .start, "Start iMessage Max", nil),
      (.portConflict, .recheck, "Check Again", .general),
      (.unresponsive, .recheck, "Check Again", .general),
      (.tokenRejected, .restart, "Restart iMessage Max", .general),
      (.failing("Cannot read the token."), .recheck, "Check Again", .general),
    ]
    for (service, primary, title, page) in table {
      let state = panel(service)
      #expect(state.primary == primary, "\(service)")
      #expect(state.primaryTitle == title, "\(service)")
      #expect(state.permissions == nil, "\(service)")
      #expect(state.attention?.page == page, "\(service)")
      #expect(state.status == (service == .stopped ? .stopped : .attention), "\(service)")
    }
  }

  /// 088 #10 and #15: a taken port and a helper that stops at launch each
  /// say what is wrong, not "Stopped" or "isn't answering".
  @Test func aTakenPortAndAFailingLaunchSayWhatIsWrong() {
    let failing = panel(.failing("Cannot read the token."))
    #expect(failing.attention?.text == "iMessage Max can’t start")
    #expect(failing.subtitle.hasSuffix("Cannot read the token."))
    #expect(failing.status == .attention)

    let taken = panel(.portConflict)
    #expect(taken.attention?.text == "Another app is using iMessage Max’s port")
    #expect(taken.subtitle.contains("Codex and Claude Desktop still can"))
  }

  // MARK: - Status menu

  @Test func aReadyHelperShowsRunningAndWhoIsConnected() throws {
    let state = panel(.running(try diagnosis()), facts: SetupFacts(connected: ["Plug"]))
    #expect(state.menu == [
      .header(.running), .separator, .connections("Connections: Plug"),
      .separator, .settings, .separator, .quit,
    ])
  }

  @Test func theMenuSaysConnectionsAreBeingCheckedBeforeTheFirstScan() throws {
    #expect(panel(.running(try diagnosis())).menu.contains(.connections("Connections: Checking…")))
    #expect(panel(.stopped, facts: SetupFacts(connected: [])).menu.contains(.connections("Connections: None")))
  }

  @Test func aMissingPermissionIsSetupFirstAndAttentionAfter() throws {
    let service = ServiceState.running(try diagnosis(contacts: false))
    let firstRun = panel(service, facts: SetupFacts(connected: []))
    #expect(firstRun.status == .settingUp)
    #expect(firstRun.menu[0] == .header(.settingUp))
    #expect(firstRun.menu[1] == .attention(Attention(text: "Allow Contacts to show names", page: .permissions)))
    let revoked = panel(service, facts: SetupFacts(connected: ["Codex"], connectSettled: true))
    #expect(revoked.status == .attention)
    #expect(revoked.attention?.page == .permissions)
  }

  @Test func everyMissingPermissionSendsTheUserToPermissions() throws {
    let table: [(ServiceState, String)] = [
      (.notRegistered, "Finish setting up"),
      (.blockedInLoginItems, "Turn on iMessage Max in Login Items"),
      (.running(try diagnosis(database: false)), "Turn on Full Disk Access"),
      (.running(try diagnosis(automation: "permission-gated")), "Allow Automation to send messages"),
    ]
    for (service, text) in table {
      #expect(panel(service).attention == Attention(text: text, page: .permissions), "\(service)")
    }
  }

  @Test func theFirstAssistantIsASuggestionNotAnAlarm() throws {
    let state = panel(.running(try diagnosis()), facts: SetupFacts(connected: []))
    #expect(state.status == .running)
    #expect(state.attention == Attention(text: "Connect your assistant", page: .connections, urgent: false))
    let settled = panel(.running(try diagnosis()), facts: SetupFacts(connected: [], connectSettled: true))
    #expect(settled.attention == nil)
  }

  @Test func aStoppedHelperSaysStoppedAndAsksNothing() {
    let state = panel(.stopped)
    #expect(state.status.word == "Stopped")
    #expect(state.attention == nil)
    #expect(state.mood == .resting)
  }

  // MARK: - Settings pages

  @Test func backAndForwardRetraceThePagesShown() {
    var history = PageHistory(.permissions)
    #expect(!history.canGoBack && !history.canGoForward)
    history.go(.connections)
    history.go(.connections)
    history.go(.about)
    #expect(history.pages == [.permissions, .connections, .about])
    history.back()
    history.back()
    #expect(history.current == .permissions)
    #expect(history.canGoForward)
    history.forward()
    #expect(history.current == .connections)
    // A new page drops the forward pages.
    history.go(.general)
    #expect(history.pages == [.permissions, .connections, .general])
    #expect(!history.canGoForward)
  }

  @Test func thePagesAreInSidebarOrder() {
    #expect(SettingsPage.allCases.map(\.title) == ["iMessage Max", "Permissions", "Connections", "About & Help"])
  }
}
