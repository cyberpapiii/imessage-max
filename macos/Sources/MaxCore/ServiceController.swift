import Foundation

public struct ServiceInspection: Sendable {
  public let configuration: ServiceConfiguration
  public let loaded: Bool
  public let processID: Int32?
  public let diagnosis: Diagnosis?
  public let problem: String?
  public let conflict: Bool

  public init(
    configuration: ServiceConfiguration, loaded: Bool, processID: Int32?, diagnosis: Diagnosis?,
    problem: String?, conflict: Bool
  ) {
    self.configuration = configuration
    self.loaded = loaded
    self.processID = processID
    self.diagnosis = diagnosis
    self.problem = problem
    self.conflict = conflict
  }
}

public enum ServiceAction: Sendable { case start, stop, restart }

/// What the companion asks of the service. `ServiceController` is the real
/// one; design fixtures supply a canned one that never touches launchd.
public protocol ServiceControlling: Sendable {
  func inspect() async throws -> ServiceInspection
  func perform(_ action: ServiceAction) async throws
  func requestPermission(_ permission: PermissionKind) async throws -> SetupPermissionReply
}

public actor ServiceController: ServiceControlling {
  private let home: URL
  private let bundledHelper: URL
  private let template: URL
  private let client = ServiceClient()
  private var operating = false

  public init(
    home: URL = FileManager.default.homeDirectoryForCurrentUser, bundledHelper: URL, template: URL
  ) {
    self.home = home
    self.bundledHelper = bundledHelper
    self.template = template
  }

  public func configuration() throws -> ServiceConfiguration {
    let path = home.appendingPathComponent(
      "Library/LaunchAgents/\(ServiceConfiguration.label).plist")
    let data = FileManager.default.fileExists(atPath: path.path) ? try Data(contentsOf: path) : nil
    return try ServiceConfiguration(data: data, home: home)
  }

  public func inspect() async throws -> ServiceInspection {
    let config = try configuration()
    let state = try await ProcessRunner.run("/bin/launchctl", arguments: ["print", target])
    let loaded = state.exitCode == 0
    let pid = Self.pid(from: state.output)
    do {
      let diagnosis = try await client.diagnose(endpoint: config.endpoint)
      let conflict = !loaded || pid != diagnosis.processID
      return ServiceInspection(
        configuration: config, loaded: loaded, processID: pid,
        diagnosis: conflict ? nil : diagnosis,
        problem: conflict ? CoreError.conflict.localizedDescription : nil, conflict: conflict)
    } catch {
      // Transport failure does not identify the listener. Check socket
      // ownership independently so a sick owned server remains repairable.
      let result = try await ProcessRunner.run(
        "/usr/sbin/lsof",
        arguments: ["-nP", "-iTCP:\(config.endpoint.port ?? 8080)", "-sTCP:LISTEN", "-t"],
        timeout: 3)
      let listeners = Set(result.output.components(separatedBy: .newlines).compactMap(Int32.init))
      let conflict = Self.hasForeignListener(ownedPID: pid, listeners: listeners)
      return ServiceInspection(
        configuration: config, loaded: loaded, processID: pid, diagnosis: nil,
        problem: loaded
          ? error.localizedDescription : (conflict ? CoreError.conflict.localizedDescription : nil),
        conflict: conflict)
    }
  }

  public func perform(_ action: ServiceAction) async throws {
    guard !operating else {
      throw CoreError.commandFailed("A service change is already in progress.")
    }
    operating = true
    defer { operating = false }
    let inspection = try await inspect()
    guard !inspection.conflict else { throw CoreError.conflict }
    let config = inspection.configuration
    switch action {
    case .stop:
      if inspection.loaded { try await launchctl(["bootout", target]) }
    case .start, .restart:
      if action == .start && inspection.loaded && inspection.diagnosis != nil { return }
      // Follow make restart's unload/load sequence. A kickstart can leave
      // this agent in its 30-second crash throttle after shutdown, which
      // makes a successful command look like a broken service.
      if inspection.loaded { try await launchctl(["bootout", target]) }
      if !config.isInstalled { try await install(config) }
      guard FileManager.default.isExecutableFile(atPath: config.binary.path) else {
        throw CoreError.commandFailed(
          "The server is missing. Reinstall iMessage Max to restore it.")
      }
      try await launchctl(["bootstrap", "gui/\(getuid())", config.plist.path])
    }
  }

  public func requestPermission(_ permission: PermissionKind) async throws -> SetupPermissionReply {
    guard !operating else {
      throw CoreError.commandFailed("A service change is already in progress.")
    }
    operating = true
    defer { operating = false }
    let inspection = try await inspect()
    guard !inspection.conflict else { throw CoreError.conflict }
    guard let pid = inspection.processID else {
      throw CoreError.commandFailed("Start iMessage Max before finishing setup.")
    }
    if inspection.diagnosis?.grants(permission) == true {
      return SetupPermissionReply(
        permission: permission, authorized: true, status: "authorized", processID: pid)
    }
    return try await client.requestPermission(
      endpoint: inspection.configuration.endpoint,
      permission: permission, expectedProcessID: pid)
  }

  private var target: String { "gui/\(getuid())/\(ServiceConfiguration.label)" }

  private func launchctl(_ arguments: [String]) async throws {
    let result = try await ProcessRunner.run("/bin/launchctl", arguments: arguments)
    guard result.exitCode == 0 else {
      throw CoreError.commandFailed(
        "macOS could not change the service. \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))"
      )
    }
  }

  private func install(_ config: ServiceConfiguration) async throws {
    let fm = FileManager.default
    guard fm.isExecutableFile(atPath: bundledHelper.path) else {
      throw CoreError.commandFailed("The app's server helper is missing. Reinstall the app.")
    }
    let signature = try await ProcessRunner.run(
      "/usr/bin/codesign", arguments: ["--verify", bundledHelper.path])
    guard signature.exitCode == 0 else {
      throw CoreError.commandFailed("The server helper's signature could not be verified.")
    }
    try fm.createDirectory(
      at: config.binary.deletingLastPathComponent(), withIntermediateDirectories: true)
    try fm.createDirectory(
      at: config.plist.deletingLastPathComponent(), withIntermediateDirectories: true)
    try fm.createDirectory(
      at: home.appendingPathComponent("Library/Logs"), withIntermediateDirectories: true)
    // Preserve an existing helper's path and signature. Installation is
    // idempotent and never replaces a running or privacy-authorized binary.
    if !fm.fileExists(atPath: config.binary.path) {
      try fm.copyItem(at: bundledHelper, to: config.binary)
    }
    let rendered = try ServiceConfiguration.renderTemplate(
      Data(contentsOf: template), binary: config.binary, home: home)
    try rendered.write(to: config.plist, options: .atomic)
  }

  public static func pid(from output: String) -> Int32? {
    for line in output.components(separatedBy: .newlines) {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.hasPrefix("pid = ") { return Int32(trimmed.dropFirst(6)) }
    }
    return nil
  }

  public static func hasForeignListener(ownedPID: Int32?, listeners: Set<Int32>) -> Bool {
    listeners.contains { $0 != ownedPID }
  }
}

public enum PermissionKind: String, Codable, Sendable { case contacts, automation }
