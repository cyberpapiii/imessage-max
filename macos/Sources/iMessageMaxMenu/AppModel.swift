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
  var panelOpen = false
  private(set) var service: ServiceState?
  private(set) var problem: String?
  private(set) var busy: Busy?
  private(set) var checking = false
  private(set) var lastCheck: Date?
  private(set) var checkMilliseconds: Int?
  private(set) var notice: Notice?
  private(set) var celebration = 0
  private(set) var loginStatus = SMAppService.mainApp.status
  /// The clients found on this Mac, in table order. Empty until the first scan.
  private(set) var clients: [ClientRow] = []
  private(set) var clientsScanned = false
  private(set) var connectSettled: Bool
  private(set) var tried: Bool
  private var pendingOn: Bool?
  @ObservationIgnored private var timer: DispatchSourceTimer?
  @ObservationIgnored private var observers: [NSObjectProtocol] = []
  @ObservationIgnored private var actionTask: Task<Void, Never>?
  @ObservationIgnored private var checkTask: Task<Void, Never>?
  @ObservationIgnored private var sleeping = false
  @ObservationIgnored private var generation = 0
  @ObservationIgnored private var noticeTimer: DispatchWorkItem?
  /// nil when this copy of the app has no valid agent plist.
  @ObservationIgnored private let controller: ServiceController?
  @ObservationIgnored private let milestones: Milestones
  @ObservationIgnored private let prepareMessages: @MainActor () async throws -> Void
  /// nil leaves the client list empty, as in the design harness.
  @ObservationIgnored private let clientContext: ClientContext?
  /// Bumped by every connect, so a scan that started before a write cannot
  /// put back what the write replaced.
  @ObservationIgnored private var clientWrites = 0
  /// How long a service change, or a permission request with its prompt, may
  /// hold `busy`. Past it the panel shows an error and the buttons return,
  /// because SMAppService and a prompt can fail to answer at all.
  @ObservationIgnored private let changeDeadline: Double
  @ObservationIgnored private let permissionDeadline: Double
  @ObservationIgnored private let log = Logger(
    subsystem: ServiceDefaults.companionBundleID, category: "Service")

  init(
    controller: ServiceController?, milestones: Milestones,
    prepareMessages: @escaping @MainActor () async throws -> Void,
    clientContext: ClientContext? = nil,
    changeDeadline: Double = 60, permissionDeadline: Double = 180
  ) {
    self.controller = controller
    self.milestones = milestones
    self.prepareMessages = prepareMessages
    self.clientContext = clientContext
    self.changeDeadline = changeDeadline
    self.permissionDeadline = permissionDeadline
    let tried = milestones.reached(.triedAssistant)
    self.tried = tried
    connectSettled =
      tried || milestones.reached(.skippedConnect) || milestones.reached(.connectedAssistant)
  }

  static func live(milestones: Milestones, clientRoot: URL? = nil) -> AppModel {
    let configuration = try? ServiceConfiguration.load()
    let home = FileManager.default.homeDirectoryForCurrentUser
    // Only a test build may point the connectors at a sandbox.
    let sandbox = configuration?.isProduction == false ? clientRoot : nil
    return AppModel(
      controller: configuration.map {
        ServiceController(
          configuration: $0, system: LiveServiceSystem(tokenFile: $0.tokenFile))
      },
      milestones: milestones,
      prepareMessages: { try await MessagesApp.ensureRunning() },
      clientContext: sandbox.map(ClientContext.sandbox(root:)) ?? .live(home: home))
  }

  var facts: SetupFacts {
    SetupFacts(
      connected: clientsScanned ? clients.filter { $0.link == .connected }.map(\.name) : nil,
      connectSettled: connectSettled)
  }

  var state: PanelState {
    PanelState(
      service: service, facts: facts, busy: busy, problem: problem, checked: lastCheck != nil)
  }
  var diagnosis: DiagnoseResult? { service?.diagnosis }
  var stopped: Bool { service == .stopped }
  var endpoint: String {
    controller?.configuration.endpoint.absoluteString
      ?? "http://\(ServiceDefaults.host):\(ServiceDefaults.port)/"
  }
  var canControl: Bool { service?.isRegistered == true && busy == nil }
  var switchOn: Bool { pendingOn ?? (service?.isRunning == true) }
  var showsSwitch: Bool { service?.isRegistered == true }
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
    Task {
      await refresh()
      // A step waiting on a launch-time grant restarts the helper anyway,
      // which also replaces an outdated one.
      if diagnosis?.grantNeedsRestartToCheck == true {
        await recheckIfStale()
      } else {
        change(.starting) { try await $0.restartIfOutdated() }
      }
    }
  }

  /// `--register-helper` from `make install`: the command is the consent to
  /// replace an older install, and a running helper restarts on the new binary.
  func registerHelper() {
    change(.starting) { controller in
      switch await controller.inspect() {
      case .legacyInstall: try await controller.migrate()
      case .notRegistered: try await controller.perform(.start)
      default: try await controller.perform(.restart)
      }
    }
  }

  /// `--unregister-helper`: removes the background item, then quits.
  func unregisterHelperAndQuit() {
    change(.stopping) { try await $0.unregister() }
    Task {
      await actionTask?.value
      NSApp.terminate(nil)
    }
  }

  /// A caller that arrives during a check waits for that check, so it acts
  /// on the state the check found.
  func refresh() async {
    if let inFlight = checkTask { return await inFlight.value }
    let task = Task { await check() }
    checkTask = task
    await task.value
    checkTask = nil
  }

  private func check() async {
    guard busy == nil, !sleeping else { return }
    guard let controller else {
      problem = CoreError.invalidConfiguration.localizedDescription
      lastCheck = .now
      return
    }
    checking = true
    defer { checking = false }
    let expectedGeneration = generation
    let start = ContinuousClock.now
    let latest = await controller.inspect()
    guard generation == expectedGeneration, busy == nil else { return }
    show(latest)
    let elapsed = start.duration(to: .now).components
    checkMilliseconds = Int(elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000)
    loginStatus = SMAppService.mainApp.status
    if panelOpen { await refreshClients() }
  }

  /// What a client needs to reach the helper. nil until the helper has
  /// written its token, which it does on first start.
  var clientAccess: ClientAccess? {
    guard let configuration = controller?.configuration,
      let token = ServiceClient.readToken(configuration.tokenFile)
    else { return nil }
    return ClientAccess(endpoint: configuration.endpoint, token: token)
  }

  /// Finds the clients on this Mac and whether each reaches the helper. A
  /// client the user is finishing in its own app keeps that note until it
  /// shows as connected.
  func refreshClients() async {
    guard let context = clientContext else {
      clientsScanned = true
      return
    }
    let access = clientAccess
    let writes = clientWrites
    let present = (try? await Self.offMainActor { Client.all.filter { $0.detect(context) } }) ?? []
    var found: [(ClientID, String, ClientLink)] = []
    for client in present {
      let link = if let access { await client.link(context, access) } else { ClientLink.notConnected }
      found.append((client.id, client.name, link))
    }
    guard writes == clientWrites else { return }
    clients = found.map { id, name, link in
      var row = ClientRow(id: id, name: name, link: link)
      if let previous = clients.first(where: { $0.id == id })?.activity {
        if case .waiting = previous, link == .connected {
          row.activity = .idle
        } else {
          row.activity = previous
        }
      }
      return row
    }
    clientsScanned = true
    settleConnectIfConnected()
  }

  /// One click: writes the client's config, or opens the client's own
  /// install step, then reads the config back to show the result.
  func connect(_ id: ClientID) {
    guard let context = clientContext, let access = clientAccess,
      let index = clients.firstIndex(where: { $0.id == id }),
      clients[index].activity != .connecting
    else { return }
    clients[index].activity = .connecting
    clientWrites += 1
    let client = Client.client(id)
    let start = ContinuousClock.now
    Task {
      var activity: ClientActivity
      var link: ClientLink?
      do {
        let result = try await client.connect(context, access)
        link = await client.link(context, access)
        activity =
          result.finishInClient && link != .connected
          ? .waiting(result.summary) : .finished(result.summary)
      } catch {
        activity = .failed(error.localizedDescription)
      }
      let elapsed = start.duration(to: .now).components
      let milliseconds = elapsed.seconds * 1000 + elapsed.attoseconds / 1_000_000_000_000_000
      log.notice(
        "Connect \(id.rawValue, privacy: .public) finished in \(milliseconds, privacy: .public) ms, link \(String(describing: link), privacy: .public)")
      clientWrites += 1
      guard let index = clients.firstIndex(where: { $0.id == id }) else { return }
      clients[index].activity = activity
      if let link { clients[index].link = link }
      if link == .connected && section == nil { notice = .linked(clients[index].name) }
      settleConnectIfConnected()
    }
  }

  /// A connected assistant retires the connect card for good.
  private func settleConnectIfConnected() {
    guard !connectSettled, clients.contains(where: { $0.link == .connected }) else { return }
    connectSettled = true
    milestones.mark(.connectedAssistant)
  }

  func runPrimary() {
    switch state.primary {
    case .start: perform(.start)
    case .restart: perform(.restart)
    case .migrate: migrate()
    case .move: moveToApplications()
    case .recheck: Task { await refresh() }
    case nil: break
    }
  }

  /// Every opening of the panel checks. A grant that macOS gives only to a
  /// new helper gets one, so turning a switch in System Settings and coming
  /// back is all a step asks.
  func panelOpened() async {
    await refresh()
    await recheckIfStale()
  }

  /// Restarts a helper that lacks a launch-time grant, unless it started
  /// moments ago. Check again restarts it either way.
  private func recheckIfStale() async {
    guard let controller, let diagnosis, diagnosis.grantNeedsRestartToCheck,
      await !controller.helperIsFresh(diagnosis.processID)
    else { return }
    recheck(announce: false)
  }

  /// A step's Check again. `announce` shows a notice when the step is still
  /// unfinished afterwards.
  func recheck(announce: Bool = true) {
    guard diagnosis?.grantNeedsRestartToCheck == true else {
      Task { await refresh() }
      return
    }
    let step = state.step
    change(.checkingAccess) { try await $0.perform(.restart) } then: { _ in
      if announce && self.state.step == step { self.notice = .setupUnfinished }
    }
  }

  /// Not now on the connect card. The Connections page still connects.
  func dismissConnect() {
    connectSettled = true
    milestones.mark(.skippedConnect)
  }

  func perform(_ action: ServiceAction) {
    let recovering = problem != nil
    if busy == nil, action != .restart { pendingOn = action == .start }
    change(action == .stop ? .stopping : .starting) {
      try await $0.perform(action)
    } then: { latest in
      self.notice = action == .stop ? .resting : .connected
      if action != .stop, latest.diagnosis?.database.accessible == true {
        self.celebrateConnection(recovering: recovering)
      }
    }
  }

  /// The consent button for replacing an install from before 2.0.
  func migrate() {
    change(.starting) { try await $0.migrate() } then: { _ in self.notice = .connected }
  }

  func request(_ permission: SetupPermission) {
    guard let controller, busy == nil else { return }
    generation += 1
    busy = permission == .automation && messagesNeedOpening ? .checkingSending : .askingPermission
    notice = nil
    problem = nil
    let prepareMessages = prepareMessages
    actionTask = Task {
      var permissionProblem: String?
      do {
        let result = try await withDeadline(seconds: permissionDeadline) { @MainActor in
          if permission == .automation { try await prepareMessages() }
          // The Contacts prompt belongs to this app, so bring it forward.
          if permission == .contacts { NSApp.activate(ignoringOtherApps: true) }
          return try await controller.requestPermission(permission)
        }
        if !result.authorized {
          permissionProblem =
            result.status == .denied
            ? "Access is off. You can enable iMessage Max in Privacy & Security, then check again."
            : (result.status == .messagesNotRunning
              ? "Messages needs a moment to open. Check again."
              : "macOS did not finish the permission request. Open Privacy & Security and check again.")
        }
      } catch { permissionProblem = error.localizedDescription }
      show(await controller.inspect())
      let confirmed = diagnosis?.grants(permission) == true
      if confirmed { problem = nil } else if let permissionProblem { problem = permissionProblem }
      notice = confirmed ? .granted(permission) : .setupUnfinished
      busy = nil
      if diagnosis?.missingGrant == nil && !milestones.reached(.welcomedSetup) {
        celebration += 1
        milestones.mark(.welcomedSetup)
      }
      actionTask = nil
    }
  }

  /// Copies the app into Applications, opens the copy and quits. The copy
  /// loses the quarantine flag so it is not translocated again.
  func moveToApplications() {
    guard busy == nil else { return }
    busy = .moving
    problem = nil
    let source = Bundle.main.bundleURL
    let destination = AppMover.destination(home: FileManager.default.homeDirectoryForCurrentUser)
    actionTask = Task {
      do {
        let target = try await Self.offMainActor {
          try AppMover.install(source, into: destination, beforeReplacing: Self.quitCopy(at:))
        }
        let strip = try? await ProcessRunner.run(
          "/usr/bin/xattr", arguments: ["-dr", "com.apple.quarantine", target.path])
        if strip?.exitCode != 0 {
          log.error(
            "Quarantine strip failed, exit \(strip.map { String($0.exitCode) } ?? "none", privacy: .public)")
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        _ = try await NSWorkspace.shared.openApplication(at: target, configuration: configuration)
        NSApp.terminate(nil)
      } catch let error as AppMover.Failure {
        problem = error.localizedDescription
        log.error("Move to Applications refused: \(error.localizedDescription, privacy: .public)")
      } catch {
        problem =
          "iMessage Max could not move itself. Drag it into Applications, then open it from there."
        log.error("Move to Applications failed: \(error.localizedDescription, privacy: .public)")
      }
      busy = nil
      actionTask = nil
    }
  }

  /// The copy in Applications may be running. Its files are about to be
  /// replaced, so it quits first, within five seconds, or the move stops.
  nonisolated private static func quitCopy(at target: URL) throws {
    let target = target.standardizedFileURL
    let running = NSWorkspace.shared.runningApplications.filter {
      $0.bundleURL?.standardizedFileURL == target && $0 != NSRunningApplication.current
        && $0.processIdentifier > 0
    }
    running.forEach { $0.terminate() }
    for _ in 0..<50 {
      if running.allSatisfy({ kill($0.processIdentifier, 0) != 0 && errno == ESRCH }) { return }
      usleep(100_000)
    }
    throw AppMover.Failure.copyStillRunning
  }

  /// Runs file work on a Dispatch queue, so a large copy or the wait for a
  /// running copy to quit never blocks the main thread.
  nonisolated private static func offMainActor<T: Sendable>(
    _ work: @escaping @Sendable () throws -> T
  ) async throws -> T {
    try await withCheckedThrowingContinuation { continuation in
      DispatchQueue.global(qos: .userInitiated).async {
        continuation.resume(with: Result { try work() })
      }
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

  /// Full Disk Access lists the app, because macOS charges the helper inside
  /// it to the app.
  func revealApp() {
    NSWorkspace.shared.activateFileViewerSelecting([Bundle.main.bundleURL])
  }

  func openLogs() {
    if let file = controller?.configuration.log, FileManager.default.fileExists(atPath: file.path) {
      NSWorkspace.shared.open(file)
    } else {
      notice = .noLog
    }
  }

  func openMessages() { MessagesApp.open() }

  func prepareToQuit() async {
    if busy?.isPermissionRequest == true { actionTask?.cancel() }
    await actionTask?.value
  }

  /// Runs one service change, then shows the state it settled on, or the
  /// error and the state as it is now.
  private func change(
    _ kind: Busy, _ operation: @escaping @Sendable (ServiceController) async throws -> ServiceState,
    then: @escaping (ServiceState) -> Void = { _ in }
  ) {
    guard let controller, busy == nil else { return }
    generation += 1
    busy = kind
    problem = nil
    notice = nil
    let deadline = changeDeadline
    actionTask = Task {
      do {
        let latest = try await withDeadline(seconds: deadline) { try await operation(controller) }
        show(latest)
        then(latest)
        log.info("Service change verified")
      } catch {
        show(await controller.inspect())
        problem = error.localizedDescription
        log.error("Service change failed")
      }
      busy = nil
      pendingOn = nil
      actionTask = nil
    }
  }

  private func show(_ latest: ServiceState) {
    service = latest
    lastCheck = .now
    if !tried, let calls = latest.diagnosis?.assistantCalls, calls > 0 {
      tried = true
      connectSettled = true
      milestones.mark(.triedAssistant)
      if state.phase == .ready {
        celebration += 1
        notice = .tried
      }
    }
    problem =
      switch latest {
      case .portConflict: CoreError.conflict.localizedDescription
      case .unresponsive:
        "iMessage Max is running but not answering yet. Restart it if this lasts."
      default: nil
      }
  }

  private func celebrateConnection(recovering: Bool) {
    if recovering || !milestones.reached(.welcomedConnection) {
      celebration += 1
      milestones.mark(.welcomedConnection)
    }
  }

  /// The header any MCP client must send, for the manual setup.
  var accessHeader: String? { clientAccess.map { "Authorization: \($0.authorization)" } }

  var diagnosticReport: String {
    """
    iMessage Max diagnostic report
    Checked: \(lastCheck?.ISO8601Format() ?? "Not checked")
    Version: \(diagnosis?.version ?? "Unknown")
    Service: \(service.map(\.summary) ?? "Unknown")
    Messages: \(diagnosis?.database.status.rawValue ?? "Unknown")
    Contacts: \(diagnosis?.contacts.status.rawValue ?? "Unknown")
    Sending permission: \(diagnosis?[.permAutomation]?.state.rawValue ?? "unknown")
    Live inbox: \(diagnosis?[.liveInbox]?.state.rawValue ?? "Unknown")
    Local connection: \(endpoint)
    Check duration: \(checkMilliseconds.map { "\($0) ms" } ?? "Unknown")
    """
  }
}

extension ServiceState {
  /// One word for the diagnostic report.
  var summary: String {
    switch self {
    case .misplaced(let translocated): translocated ? "translocated" : "outside Applications"
    case .legacyInstall: "older install present"
    case .blockedInLoginItems: "off in Login Items"
    case .portConflict: "port in use"
    case .notRegistered: "not set up"
    case .stopped: "stopped"
    case .unresponsive: "not answering"
    case .tokenRejected: "access key refused"
    case .running: "running"
    }
  }
}
