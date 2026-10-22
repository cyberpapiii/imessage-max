import AppKit
import Foundation
import MaxCore
import OSLog
import Observation
import ServiceManagement

@MainActor @Observable
final class AppModel {
  var section: PanelSection?
  var maximumPanelHeight: CGFloat = 720
  /// True while the panel is on screen; the face only animates then.
  var panelOpen = false
  private(set) var inspection: ServiceInspection?
  private(set) var problem: String?
  private(set) var busy: String?
  private(set) var checking = false
  private(set) var lastCheck: Date?
  private(set) var checkMilliseconds: Int?
  private(set) var notice: String?
  private(set) var celebration = 0
  private(set) var loginStatus = SMAppService.mainApp.status
  @ObservationIgnored private var timer: DispatchSourceTimer?
  @ObservationIgnored private var observers: [NSObjectProtocol] = []
  @ObservationIgnored private var actionTask: Task<Void, Never>?
  @ObservationIgnored private let controller: ServiceController
  @ObservationIgnored private var sleeping = false
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var requestingPermission = false
  @ObservationIgnored private var noticeTimer: DispatchWorkItem?
  @ObservationIgnored private let fixture: String?
  /// Where the switch is heading while a start or stop is under way.
  private var pendingOn: Bool?
  @ObservationIgnored private let log = Logger(
    subsystem: "com.cyberpapiii.imessage-max.menubar", category: "Service")

  /// `fixture` names a canned state for design checks; it never touches the
  /// real service.
  init(fixture: String? = nil) {
    self.fixture = fixture
    let resources = Bundle.main.resourceURL ?? Bundle.main.bundleURL
    controller = ServiceController(
      bundledHelper: resources.appendingPathComponent("imessage-max"),
      template: resources.appendingPathComponent("local.imessage-max.plist"))
    if let fixture { load(fixture) }
  }

  var diagnosis: Diagnosis? { inspection?.diagnosis }
  var stopped: Bool {
    inspection != nil && inspection?.loaded == false && inspection?.conflict == false
  }
  var endpoint: String {
    inspection?.configuration.endpoint.absoluteString ?? "http://127.0.0.1:8080/"
  }
  var canControl: Bool { inspection != nil && inspection?.conflict == false && busy == nil }
  var ready: Bool { diagnosis?.readiness == .ready }
  var switchOn: Bool { pendingOn ?? (inspection?.loaded == true) }
  /// The switch appears once there is an installed service to turn on or off.
  var showsSwitch: Bool { inspection?.configuration.isInstalled == true }
  var messagesNeedOpening: Bool {
    diagnosis?.needsMessagesForSendingCheck == true
  }

  var title: String {
    if let busy { return busy }
    if lastCheck == nil && problem == nil { return "Checking in…" }
    if let diagnosis {
      switch diagnosis.readiness {
      case .messages: return "A little setup first"
      case .contacts: return "Let’s add names"
      case .sending: return "Ready to read"
      case .ready: return "Ready to help"
      }
    }
    if stopped {
      return inspection?.configuration.isInstalled == true
        ? "Taking a break" : "Hello, iMessage Max"
    }
    return "Let’s get connected"
  }

  var subtitle: String {
    if busy != nil { return "We’ll check that everything worked." }
    if let diagnosis {
      switch diagnosis.readiness {
      case .messages: return "Give iMessage Max access to Messages on this Mac."
      case .contacts: return "Messages are available. Contacts make names familiar."
      case .sending:
        return messagesNeedOpening
          ? "Open Messages so we can check sending. Your assistants can already read messages."
          : "Your assistants can read messages. Let’s check sending access."
      case .ready: return "Your messages. Your assistants. All on this Mac."
      }
    }
    if stopped {
      return inspection?.configuration.isInstalled == true
        ? "Start whenever you need your assistants again."
        : "A small helper connects your assistants to Messages."
    }
    return "Your messages stay on this Mac. We’ll help with the connection."
  }

  var primaryTitle: String {
    if busy != nil { return "Working…" }
    if diagnosis != nil && !ready { return messagesNeedOpening ? "Check sending" : "Finish setup" }
    if stopped {
      return inspection?.configuration.isInstalled == true
        ? "Start iMessage Max" : "Set up iMessage Max"
    }
    if diagnosis != nil { return "Connect an assistant" }
    return "Check again"
  }

  var mood: CompanionMood {
    if busy != nil || (lastCheck == nil && problem == nil) { return .working }
    if problem != nil { return .trouble }
    if stopped { return .resting }
    if ready { return .ready }
    return diagnosis != nil ? .needsYou : .trouble
  }

  func startMonitoring() {
    guard timer == nil, fixture == nil else { return }
    let timer = DispatchSource.makeTimerSource(queue: .main)
    timer.schedule(deadline: .now() + 60, repeating: 60, leeway: .seconds(10))
    timer.setEventHandler { @Sendable [weak self] in
      Task { @MainActor [weak self] in await self?.refresh() }
    }
    self.timer = timer
    timer.resume()
    let center = NSWorkspace.shared.notificationCenter
    observers.append(
      center.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) {
        [weak self] _ in
        Task { @MainActor in self?.sleeping = true }
      })
    observers.append(
      center.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) {
        [weak self] _ in
        Task { @MainActor in
          self?.sleeping = false
          await self?.refresh()
        }
      })
    Task { await refresh() }
  }

  func refresh() async {
    guard !checking, busy == nil, !sleeping, fixture == nil else { return }
    checking = true
    defer { checking = false }
    let expectedGeneration = generation
    let start = ContinuousClock.now
    do {
      let latest = try await controller.inspect()
      guard generation == expectedGeneration, busy == nil else { return }
      inspection = latest
      problem = inspection?.problem
      lastCheck = .now
      let elapsed = start.duration(to: .now).components
      checkMilliseconds = Int(elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000)
    } catch {
      guard generation == expectedGeneration, busy == nil else { return }
      inspection = nil
      problem = error.localizedDescription
    }
    loginStatus = SMAppService.mainApp.status
  }

  func perform(_ action: ServiceAction) {
    guard busy == nil else { return }
    generation += 1
    let recovering = problem != nil
    busy = action == .stop ? "Taking a break…" : "Getting ready…"
    problem = nil
    notice = nil
    if fixture != nil {
      pendingOn = action != .stop
      simulate(action == .stop ? "stopped" : "ready") { [self] in
        notice =
          action == .stop ? "Resting until you start it again." : "Connected. You’re back in business."
        if action != .stop { celebration += 1 }
      }
      return
    }
    if action != .restart { pendingOn = action == .start }
    actionTask = Task {
      var operationProblem: String?
      do {
        try await controller.perform(action)
        let deadline = Date().addingTimeInterval(12)
        var latest: ServiceInspection?
        repeat {
          latest = try await controller.inspect()
          if action == .stop ? latest?.loaded == false : latest?.diagnosis != nil { break }
          await Self.pause()
        } while Date() < deadline && !Task.isCancelled
        inspection = latest
        let verified = action == .stop ? latest?.loaded == false : latest?.diagnosis != nil
        guard verified else {
          throw CoreError.commandFailed(
            "The service hasn’t responded yet. Check again in a moment.")
        }
        lastCheck = .now
        if action == .stop {
          notice = "Resting until you start it again."
        } else {
          notice = "Connected. You’re back in business."
          if diagnosis?.database.accessible == true
            && (recovering || !UserDefaults.standard.bool(forKey: "hasWelcomedConnection"))
          {
            celebration += 1
            UserDefaults.standard.set(true, forKey: "hasWelcomedConnection")
          }
        }
        log.info("Service action verified")
      } catch {
        operationProblem = error.localizedDescription
        log.error("Service action failed")
      }
      if let operationProblem {
        await reconcile()
        problem = operationProblem
      } else {
        problem = inspection?.problem
      }
      busy = nil
      pendingOn = nil
      actionTask = nil
    }
  }

  func request(_ permission: PermissionKind) {
    guard busy == nil else { return }
    generation += 1
    requestingPermission = true
    busy =
      permission == .automation && messagesNeedOpening
      ? "Checking sending…" : "Waiting for permission…"
    notice = nil
    problem = nil
    if fixture != nil {
      simulate("ready") { [self] in
        notice = permission == .automation ? "Sending is ready." : "Contact names are ready."
        celebration += 1
      }
      return
    }
    actionTask = Task {
      var permissionProblem: String?
      do {
        if permission == .automation { try await ensureMessagesRunning() }
        let result = try await controller.requestPermission(permission)
        if !result.authorized {
          permissionProblem =
            result.status == "denied"
            ? "Access is off. You can enable iMessage Max in Privacy & Security, then check again."
            : (result.status == "messages_not_running"
              ? "Messages needs a moment to open. Check again."
              : "macOS did not finish the permission request. Open Privacy & Security and check again.")
        }
      } catch { permissionProblem = error.localizedDescription }
      await reconcile()
      let confirmed =
        permission == .automation
        ? diagnosis?.capabilities["perm_automation"]?.state == "supported"
        : diagnosis?.namesReady == true
      if confirmed { problem = nil } else if let permissionProblem { problem = permissionProblem }
      notice =
        confirmed
        ? (permission == .automation ? "Sending is ready." : "Contact names are ready.")
        : "Setup isn’t finished yet. Check the step below."
      busy = nil
      requestingPermission = false
      if ready && !UserDefaults.standard.bool(forKey: "hasWelcomedSetup") {
        celebration += 1
        UserDefaults.standard.set(true, forKey: "hasWelcomedSetup")
      }
      actionTask = nil
    }
  }

  func setLaunchAtLogin(_ enabled: Bool) {
    do {
      if enabled {
        try SMAppService.mainApp.register()
      } else {
        try SMAppService.mainApp.unregister()
      }
      loginStatus = SMAppService.mainApp.status
    } catch { problem = "Could not change launch at login. \(error.localizedDescription)" }
  }

  func copy(_ text: String, acknowledgement: String = "Copied. Ready to paste.") {
    NSPasteboard.general.clearContents()
    NSPasteboard.general.setString(text, forType: .string)
    notice = acknowledgement
  }

  /// A notice is a toast: it leaves on its own after long enough to read.
  func noticeAppeared() {
    noticeTimer?.cancel()
    guard let shown = notice else { return }
    let timer = DispatchWorkItem { [weak self] in
      MainActor.assumeIsolated { if self?.notice == shown { self?.notice = nil } }
    }
    noticeTimer = timer
    DispatchQueue.main.asyncAfter(
      deadline: .now() + 2.4 + 0.04 * Double(shown.count), execute: timer)
  }

  func clearNotice() {
    noticeTimer?.cancel()
    notice = nil
  }

  func openSettings(_ pane: String) {
    if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") {
      NSWorkspace.shared.open(url)
    }
  }

  func revealHelper() {
    guard let binary = inspection?.configuration.binary else { return }
    NSWorkspace.shared.activateFileViewerSelecting([binary])
  }

  func openLogs() {
    let file = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(
      "Library/Logs/imessage-max.stderr.log")
    if FileManager.default.fileExists(atPath: file.path) {
      NSWorkspace.shared.open(file)
    } else {
      notice = "No service log yet. Start iMessage Max first."
    }
  }

  func openMessages() {
    NSWorkspace.shared.open(URL(fileURLWithPath: "/System/Applications/Messages.app"))
  }

  private func ensureMessagesRunning() async throws {
    guard
      NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.MobileSMS").isEmpty
    else { return }
    guard
      let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.MobileSMS")
    else {
      throw CoreError.commandFailed("Messages is missing from this Mac.")
    }
    let configuration = NSWorkspace.OpenConfiguration()
    configuration.activates = false
    _ = try await NSWorkspace.shared.openApplication(at: url, configuration: configuration)
  }

  func prepareToQuit() async {
    // Permission prompts can be cancelled without touching the service.
    // A requested start/stop/restart finishes before the companion exits.
    // Cancelling a daemon-owned request stops our wait. Any macOS consent
    // dialog belongs to the helper and remains until the user answers it.
    if requestingPermission { actionTask?.cancel() }
    await actionTask?.value
  }

  private func reconcile() async {
    do {
      inspection = try await controller.inspect()
      lastCheck = .now
      problem = inspection?.problem
    } catch {
      inspection = nil
      problem = error.localizedDescription
    }
  }

  var clientConfiguration: String {
    """
    {
      "mcpServers": {
        "imessage-max": {
          "url": "\(endpoint)"
        }
      }
    }
    """
  }

  var plugConfiguration: String {
    """
    [servers.imessage-max]
    transport = "http"
    url = "\(endpoint)"
    protocol = "legacy"
    """
  }

  var codexConfiguration: String {
    """
    [mcp_servers.imessage-max]
    url = "\(endpoint)"
    """
  }

  var diagnosticReport: String {
    let permission = diagnosis?.capabilities["perm_automation"]?.state ?? "unknown"
    return """
      iMessage Max diagnostic report
      Checked: \(lastCheck?.ISO8601Format() ?? "Not checked")
      Version: \(diagnosis?.version ?? "Unknown")
      Service loaded: \(inspection?.loaded == true)
      Messages: \(diagnosis?.database.status ?? "Unknown")
      Contacts: \(diagnosis?.contacts.status ?? "Unknown")
      Sending permission: \(permission)
      Live inbox: \(diagnosis?.capabilities["live_inbox"]?.state ?? "Unknown")
      Local connection: \(endpoint)
      Check duration: \(checkMilliseconds.map { "\($0) ms" } ?? "Unknown")
      """
  }

  // MARK: Design fixtures

  private func load(_ name: String) {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let installed = try? PropertyListSerialization.data(
      fromPropertyList: [
        "Label": ServiceConfiguration.label,
        "ProgramArguments": ["/usr/local/bin/imessage-max", "--http"],
      ], format: .xml, options: 0)
    func diagnosis(messages: Bool, contacts: String, sending: String, detail: String? = nil)
      -> Diagnosis?
    {
      let json: [String: Any] = [
        "version": "1.8.0", "process_id": 4242, "status": "ok",
        "database": [
          "accessible": messages, "status": messages ? "accessible" : "permission_denied",
        ],
        "contacts": ["authorized": contacts == "authorized", "status": contacts],
        "capabilities": [
          "perm_automation": ["state": sending, "detail": detail as Any? ?? NSNull()],
          "send_text_dm": ["state": "supported"], "live_inbox": ["state": "supported"],
        ],
      ]
      return (try? JSONSerialization.data(withJSONObject: json)).flatMap {
        try? JSONDecoder().decode(Diagnosis.self, from: $0)
      }
    }
    var loaded = true
    var data = installed
    var result: Diagnosis?
    var trouble: String?
    switch name {
    case "fresh": (loaded, data) = (false, nil)
    case "stopped": loaded = false
    case "setup-messages":
      result = diagnosis(messages: false, contacts: "not_determined", sending: "unknown")
    case "setup-contacts":
      result = diagnosis(messages: true, contacts: "not_determined", sending: "unknown")
    case "setup-sending":
      result = diagnosis(
        messages: true, contacts: "authorized", sending: "unknown", detail: "messages_not_running")
    case "problem": trouble = CoreError.invalidResponse.errorDescription
    case "working":
      result = diagnosis(messages: true, contacts: "authorized", sending: "supported")
      busy = "Getting ready…"
    default: result = diagnosis(messages: true, contacts: "authorized", sending: "supported")
    }
    guard let configuration = try? ServiceConfiguration(data: data, home: home) else { return }
    inspection = ServiceInspection(
      configuration: configuration, loaded: loaded, processID: loaded ? 4242 : nil,
      diagnosis: result, problem: trouble, conflict: false)
    problem = trouble
    if name != "checking" { lastCheck = .now }
  }

  private func simulate(_ name: String, then finish: @escaping @MainActor () -> Void) {
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
      MainActor.assumeIsolated {
        self?.load(name)
        self?.busy = nil
        self?.pendingOn = nil
        finish()
      }
    }
  }

  private static func pause() async {
    await withCheckedContinuation { continuation in
      DispatchQueue.global().asyncAfter(deadline: .now() + 0.35) { continuation.resume() }
    }
  }
}
