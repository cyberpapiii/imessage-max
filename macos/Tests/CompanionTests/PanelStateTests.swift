import Foundation
import IMessageMaxContract
import MaxBrand
import MaxCore
import Testing

@testable import iMessageMaxMenu

private let home = URL(fileURLWithPath: "/tmp/max-home")

private func inspection(loaded: Bool, installed: Bool = true, diagnosis: DiagnoseResult? = nil) throws
  -> ServiceInspection
{
  let plist = try PropertyListSerialization.data(
    fromPropertyList: [
      "Label": ServiceConfiguration.label, "ProgramArguments": ["/tmp/imessage-max", "--http"],
    ], format: .xml, options: 0)
  return ServiceInspection(
    configuration: try ServiceConfiguration(data: installed ? plist : nil, home: home),
    loaded: loaded, processID: loaded ? 1 : nil, diagnosis: diagnosis, problem: nil,
    conflict: false)
}

private func diagnosis(contacts: Bool = true, automation: String = "supported") throws
  -> DiagnoseResult
{
  try JSONDecoder().decode(
    DiagnoseResult.self,
    from: Data(
      """
      {"version":"1.8.0","process_id":1,"status":"ok",
      "database":{"path":"~/Library/Messages/chat.db","accessible":true,"status":"accessible"},
      "contacts":{"authorized":\(contacts),"status":"\(contacts ? "authorized" : "denied")"},
      "capabilities":{"perm_automation":{"state":"\(automation)"},"send_text_dm":{"state":"supported"}}}
      """.utf8))
}

@Test func firstCheckIsWorkingAndOffersNothingYet() {
  let state = PanelState(inspection: nil, busy: nil, problem: nil, checked: false)
  #expect(state.title == "Checking in…")
  #expect(state.mood == .working)
  #expect(state.primary == .recheck)
  #expect(!state.primaryEnabled)
}

@Test func readyServiceOffersTheConnectionPage() throws {
  let state = PanelState(
    inspection: try inspection(loaded: true, diagnosis: diagnosis()), busy: nil, problem: nil,
    checked: true)
  #expect(state.title == "Ready to help")
  #expect(state.primary == .connect)
  #expect(state.mood == .ready)
}

@Test func aWaitingSetupStepHidesThePrimaryButton() throws {
  let state = PanelState(
    inspection: try inspection(loaded: true, diagnosis: diagnosis(contacts: false)), busy: nil,
    problem: nil, checked: true)
  #expect(state.title == "Let’s add names")
  #expect(state.primary == nil)
  #expect(state.mood == .needsYou)
}

@Test func busyOverridesTheHeadlineButKeepsTheButtonsPlace() throws {
  let state = PanelState(
    inspection: try inspection(loaded: false), busy: .starting, problem: nil, checked: true)
  #expect(state.title == "Getting ready…")
  #expect(state.primaryTitle == "Working…")
  #expect(state.primary == .start)
  #expect(!state.primaryEnabled)
}

@Test func aProblemTroublesTheFaceNotTheHeadline() throws {
  let state = PanelState(
    inspection: try inspection(loaded: false, installed: false), busy: nil, problem: "x",
    checked: true)
  #expect(state.title == "Hello, iMessage Max")
  #expect(state.primaryTitle == "Set up iMessage Max")
  #expect(state.mood == .trouble)
}

@Test func onlyAnUnfinishedSetupNoticeIsNeutral() {
  #expect(Notice.setupUnfinished.tone == .neutral)
  for notice in [Notice.resting, .connected, .granted(.contacts), .granted(.automation)] {
    #expect(notice.tone == .good)
  }
}
