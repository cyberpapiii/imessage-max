import AppKit
import Foundation
import IMessageMaxContract
import MaxCore
import Observation
import OSLog
import ServiceManagement

@MainActor @Observable
final class AppModel {
  var section: PanelSection?
  var maximumPanelHeight = Design.maximumPanelHeight
  /// True while the panel is on screen; the face only animates then.
  var panelOpen = false
  private(set) var inspection: ServiceInspection?
  private(set) var problem: String?
  private(set) var busy: Busy?
  private(set) var checking = false
  private(set) var lastCheck: Date?
  private(set) var checkMilliseconds: Int?
  private(set) var notice: Notice?
  private(set) var celebration = 0
  private(set) var loginStatus = SMAppService.mainApp.status
  /// Where the switch is heading while a start or stop is under way.
  private var pendingOn: Bool?
  @ObservationIgnored private var timer: DispatchSourceTimer?
  @ObservationIgnored private var observers: [NSObjectProtocol] = []
  @ObservationIgnored private var actionTask: Task<Void, Never>?
  @ObservationIgnored private var sleeping = false
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var noticeTimer: DispatchWorkItem?
  @ObservationIgnored private let service: any ServiceControlling
  @ObservationIgnored private let milestones: Milestones
  @ObservationIgnored private let prepareMessages: @MainActor () async throws -> Void
  @ObservationIgnored private let log = Logger(
    subsystem: "com.cyberpapiii.imessage-max.menubar", category: "Service")

  /// `prepareMessages` runs before a sending check; the live app opens
  /// Messages there.
  init(
    service: any ServiceControlling, milestones: Milestones,
    prepareMessages: @escaping @MainActor () async throws -> Void
  ) {
    self.service = service
    self.milestones = milestones
    self.prepareMessages = prepareMessages
  }

  /// The real service, using the helper and launchd template bundled with
  /// this app for a fresh install.
  static func live(milestones: Milestones) -> AppModel {
    let resources = Bundle.main.resourceURL ?? Bundle.main.bundleURL
    return AppModel(
      service: ServiceController(
        bundledHelper: resources.appendingPathComponent("imessage-max"),
        template: resources.appendingPathComponent("\(ServiceDefaults.launchdLabel).plist")),
      milestones: milestones,
      prepareMessages: { try await MessagesApp.ensureRunning() })
  }

  var state: PanelState {
    PanelState(inspection: inspection, busy: busy, problem: problem, checked: lastCheck != nil)
  }
  var diagnosis: DiagnoseResult? { inspection?.diagnosis }
  var stopped: Bool {
    inspection != nil && inspection?.loaded == false && inspection?.conflict == false
  }
  var endpoint: String {
    inspection?.configuration.endpoint.absoluteString
      ?? "http://\(ServiceDefaults.host):\(ServiceDefaults.port)/"
  }
  var canControl: Bool { inspection != nil && inspection?.conflict == false && busy == nil }
  var ready: Bool { diagnosis?.readiness == .ready }
  var switchOn: Bool { pendingOn ?? (inspection?.loaded == true) }
  /// The switch appears once there is an installed service to turn on or off.
  var showsSwitch: Bool { inspection?.configuration.isInstalled == true }
  var messagesNeedOpening: Bool {
    diagnosis?.needsMessagesForSendingCheck == true
  }

  func startMonitoring() {
    guard timer == nil else { return }
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
    guard !checking, busy == nil, !sleeping else { return }
    checking = true
    defer { checking = false }
    let expectedGeneration = generation
    let start = ContinuousClock.now
    do {
      let latest = try await service.inspect()
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

  func runPrimary() {
    switch state.primary {
    case .connect: section = .connection
    case .start: perform(.start)
    case .recheck: Task { await refresh() }
    case nil: break
    }
  }

  func perform(_ action: ServiceAction) {
    guard busy == nil else { return }
    generation += 1
    let recovering = problem != nil
    busy = action == .stop ? .stopping : .starting
    problem = nil
    notice = nil
    if action != .restart { pendingOn = action == .start }
    actionTask = Task {
      var operationProblem: String?
      do {
        try await service.perform(action)
        let deadline = Date().addingTimeInterval(12)
        var latest: ServiceInspection?
        repeat {
          latest = try await service.inspect()
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
          notice = .resting
        } else {
          notice = .connected
          if diagnosis?.database.accessible == true
            && (recovering || !milestones.reached(.welcomedConnection))
          {
            celebration += 1
            milestones.mark(.welcomedConnection)
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

  func request(_ permission: SetupPermission) {
    guard busy == nil else { return }
    generation += 1
    busy = permission == .automation && messagesNeedOpening ? .checkingSending : .askingPermission
    notice = nil
    problem = nil
    actionTask = Task {
      var permissionProblem: String?
      do {
        if permission == .automation { try await prepareMessages() }
        let result = try await service.requestPermission(permission)
        if !result.authorized {
          permissionProblem =
            result.status == .denied
            ? "Access is off. You can enable iMessage Max in Privacy & Security, then check again."
            : (result.status == .messagesNotRunning
              ? "Messages needs a moment to open. Check again."
              : "macOS did not finish the permission request. Open Privacy & Security and check again.")
        }
      } catch { permissionProblem = error.localizedDescription }
      await reconcile()
      let confirmed = diagnosis?.grants(permission) == true
      if confirmed { problem = nil } else if let permissionProblem { problem = permissionProblem }
      notice = confirmed ? .granted(permission) : .setupUnfinished
      busy = nil
      if ready && !milestones.reached(.welcomedSetup) {
        celebration += 1
        milestones.mark(.welcomedSetup)
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
    notice = Notice(text: acknowledgement)
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
      deadline: .now() + 2.4 + 0.04 * Double(shown.text.count), execute: timer)
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
      ServiceDefaults.stderrLogPath)
    if FileManager.default.fileExists(atPath: file.path) {
      NSWorkspace.shared.open(file)
    } else {
      notice = .noLog
    }
  }

  func openMessages() { MessagesApp.open() }

  func prepareToQuit() async {
    // Permission prompts can be cancelled without touching the service.
    // A requested start/stop/restart finishes before the companion exits.
    // Cancelling a daemon-owned request stops our wait. Any macOS consent
    // dialog belongs to the helper and remains until the user answers it.
    if busy?.isPermissionRequest == true { actionTask?.cancel() }
    await actionTask?.value
  }

  private func reconcile() async {
    do {
      inspection = try await service.inspect()
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
    """
    iMessage Max diagnostic report
    Checked: \(lastCheck?.ISO8601Format() ?? "Not checked")
    Version: \(diagnosis?.version ?? "Unknown")
    Service loaded: \(inspection?.loaded == true)
    Messages: \(diagnosis?.database.status.rawValue ?? "Unknown")
    Contacts: \(diagnosis?.contacts.status.rawValue ?? "Unknown")
    Sending permission: \(diagnosis?[.permAutomation]?.state.rawValue ?? "unknown")
    Live inbox: \(diagnosis?[.liveInbox]?.state.rawValue ?? "Unknown")
    Local connection: \(endpoint)
    Check duration: \(checkMilliseconds.map { "\($0) ms" } ?? "Unknown")
    """
  }

  private static func pause() async {
    await withCheckedContinuation { continuation in
      DispatchQueue.global().asyncAfter(deadline: .now() + 0.35) { continuation.resume() }
    }
  }
}
