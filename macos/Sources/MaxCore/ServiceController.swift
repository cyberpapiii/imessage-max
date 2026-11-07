import Foundation
import IMessageMaxContract

public enum ServiceAction: Sendable { case start, stop, restart }

/// Registers, starts, stops and inspects the helper inside this app. Every
/// change waits until the observed state shows it, then returns that state.
public actor ServiceController {
  public nonisolated let configuration: ServiceConfiguration
  private let system: any ServiceSystem
  private let home: URL
  /// nil for a test build, which must never touch the old install.
  private let legacy: LegacyInstall?
  private var operating = false
  /// About 18 seconds at the live system's 0.35 second pause. A kickstart
  /// waits out the plist's 10 second ThrottleInterval.
  private static let attempts = 50

  public init(
    configuration: ServiceConfiguration, system: any ServiceSystem = LiveServiceSystem(),
    home: URL = FileManager.default.homeDirectoryForCurrentUser
  ) {
    self.configuration = configuration
    self.system = system
    self.home = home
    legacy = configuration.isProduction ? LegacyInstall(home: home) : nil
  }

  public func inspect() async -> ServiceState { ServiceState(await observe()) }

  public func perform(_ action: ServiceAction) async throws -> ServiceState {
    try await exclusively {
      let state = await inspect()
      switch (action, state) {
      case (_, .misplaced), (_, .legacyInstall), (_, .blockedInLoginItems), (_, .portConflict):
        throw CoreError.notReady(state)
      case (.stop, .running), (.stop, .unresponsive), (.stop, .tokenRejected):
        try await system.run(.bootout(label: configuration.label))
        return try await converge { $0 == .stopped }
      case (.stop, _), (.start, .running), (.start, .unresponsive), (.start, .tokenRejected):
        return state
      case (_, .notRegistered):
        try await system.run(.register(plistName: configuration.plistName))
        return try await converge { $0.diagnosis != nil }
      case (.start, _), (.restart, _):
        let previous = state.diagnosis?.processID
        try await kickstart(restart: state.isRunning)
        return try await converge { $0.diagnosis.map { $0.processID != previous } ?? false }
      }
    }
  }

  /// Replaces the pre-2.0 install: boots out its job, removes its plist and
  /// copied helper, then registers this app's helper. Each step reads what is
  /// there now, so a run after a crash that left the old files finishes the
  /// rest. A crash after the files are gone leaves `.notRegistered`, which
  /// `perform(.start)` finishes.
  public func migrate() async throws -> ServiceState {
    guard let legacy else { throw CoreError.notReady(await inspect()) }
    return try await exclusively {
      let state = await inspect()
      guard state == .legacyInstall else { throw CoreError.notReady(state) }
      if await system.job(label: LegacyInstall.label) != nil {
        try await system.run(.bootout(label: LegacyInstall.label))
        // The old files stay until the port is free, so a listener that
        // outlives the bootout leaves the old install whole.
        guard await portFrees() else { throw CoreError.conflict }
      }
      try legacy.removeFiles()
      if await system.agentStatus(plistName: configuration.plistName) == .notRegistered {
        try await system.run(.register(plistName: configuration.plistName))
      }
      return try await converge { $0.diagnosis != nil }
    }
  }

  /// After an update the running helper is the old binary until it restarts.
  public func restartIfOutdated() async throws -> ServiceState {
    let state = await inspect()
    guard let pid = state.diagnosis?.processID,
      await system.isOutdated(pid: pid, executable: configuration.helper)
    else { return state }
    return try await perform(.restart)
  }

  /// The helper started under the plist's 10 second ThrottleInterval ago. A
  /// restart now would wait out the rest, and the helper predates no grant a
  /// person could have turned on since.
  public func helperIsFresh(_ processID: Int32) async -> Bool {
    guard let started = await system.startTime(pid: processID) else { return false }
    return Date.now.timeIntervalSince(started) < 10
  }

  public func unregister() async throws -> ServiceState {
    try await exclusively {
      if await system.agentStatus(plistName: configuration.plistName) != .notRegistered {
        try await system.run(.unregister(plistName: configuration.plistName))
      }
      return await inspect()
    }
  }

  /// Contacts is asked in this process, then the helper restarts, because it
  /// keeps the answer it read at launch. Automation goes to the helper, which
  /// macOS also charges to this app.
  public func requestPermission(_ permission: SetupPermission) async throws -> SetupPermissionReply {
    try await exclusively {
      let state = await inspect()
      guard let diagnosis = state.diagnosis else { throw CoreError.notReady(state) }
      if diagnosis.grants(permission) {
        return SetupPermissionReply(
          permission: permission, authorized: true, status: .authorized,
          processID: diagnosis.processID)
      }
      guard permission == .contacts else {
        return try await system.requestHelperPermission(
          permission, endpoint: configuration.endpoint, processID: diagnosis.processID)
      }
      let status = await system.requestContactsAccess()
      guard PermissionStatus.namesAvailable.contains(status) else {
        return SetupPermissionReply(
          permission: .contacts, authorized: false, status: status,
          processID: diagnosis.processID)
      }
      try await kickstart(restart: true)
      let restarted = try await converge {
        $0.diagnosis.map { $0.processID != diagnosis.processID } ?? false
      }
      let processID = restarted.diagnosis?.processID ?? diagnosis.processID
      return SetupPermissionReply(
        permission: .contacts, authorized: true, status: status, processID: processID)
    }
  }

  private func observe() async -> ServiceObservation {
    let location = AppLocation(bundleURL: configuration.bundleURL, home: home)
    var legacyPresent = false
    if let legacy {
      legacyPresent = legacy.isPresent(
        jobLoaded: await system.job(label: LegacyInstall.label) != nil)
    }
    let agent = await system.agentStatus(plistName: configuration.plistName)
    let job = await system.job(label: configuration.label)
    let reply = await system.diagnose(endpoint: configuration.endpoint)
    let diagnosis = reply.diagnosis
    var foreign = false
    if diagnosis == nil || diagnosis?.processID != job?.pid {
      foreign = await system.listeners(port: configuration.port).contains { $0 != job?.pid }
    }
    return ServiceObservation(
      location: location, legacy: legacyPresent, agent: agent, job: job, diagnosis: diagnosis,
      refused: reply == .refused, foreignListener: foreign)
  }

  /// A job launchd no longer holds, as after a stop, cannot be kickstarted;
  /// registering again loads it.
  private func kickstart(restart: Bool) async throws {
    if await system.job(label: configuration.label) != nil {
      try await system.run(.kickstart(label: configuration.label, restart: restart))
    } else {
      try await system.run(.unregister(plistName: configuration.plistName))
      try await system.run(.register(plistName: configuration.plistName))
    }
  }

  /// Waits until `done`. Turned off in Login Items is an end state: launchd
  /// will not run the helper until the user turns it on, so waiting is futile.
  private func converge(until done: (ServiceState) -> Bool) async throws -> ServiceState {
    for attempt in 1...Self.attempts {
      let state = await inspect()
      if done(state) { return state }
      if state == .blockedInLoginItems { throw CoreError.notReady(state) }
      if attempt < Self.attempts { await system.pause() }
    }
    throw CoreError.commandFailed("The service hasn’t responded yet. Check again in a moment.")
  }

  /// Whether the port has no listener but this app's own helper, within the wait.
  private func portFrees() async -> Bool {
    for attempt in 1...Self.attempts {
      let ours = await system.job(label: configuration.label)?.pid
      if await system.listeners(port: configuration.port).subtracting(ours.map { [$0] } ?? []).isEmpty {
        return true
      }
      if attempt < Self.attempts { await system.pause() }
    }
    return false
  }

  private func exclusively<T: Sendable>(_ body: () async throws -> T) async throws -> T {
    guard !operating else {
      throw CoreError.commandFailed("A service change is already in progress.")
    }
    operating = true
    defer { operating = false }
    return try await body()
  }
}
