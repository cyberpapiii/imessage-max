import Contacts
import Foundation
import IMessageMaxContract
import ServiceManagement

/// Every part of macOS the controller touches. Tests and the design harness
/// replace it; the controller's rules stay the same.
public protocol ServiceSystem: Sendable {
  func agentStatus(plistName: String) async -> AgentStatus
  /// nil when launchd has no job with this label.
  func job(label: String) async -> Job?
  func diagnose(endpoint: URL) async -> DiagnoseReply
  func listeners(port: Int) async -> Set<Int32>
  func run(_ command: SystemCommand) async throws
  /// Whether `pid` started before the file at `executable` was last replaced.
  func isOutdated(pid: Int32, executable: URL) async -> Bool
  /// When `pid` started, or nil when it cannot be read.
  func startTime(pid: Int32) async -> Date?
  /// Asks for Contacts in this process. macOS charges the helper inside the
  /// app to the app, and a helper that asks for itself is denied with no prompt.
  func requestContactsAccess() async -> PermissionStatus
  func requestHelperPermission(_ permission: SetupPermission, endpoint: URL, processID: Int32)
    async throws -> SetupPermissionReply
  func pause() async
}

extension ServiceSystem {
  public func startTime(pid: Int32) async -> Date? { nil }
}

public enum SystemCommand: Sendable, Equatable {
  case register(plistName: String)
  case unregister(plistName: String)
  /// `launchctl kickstart`, with `-k` when `restart` kills a running process first.
  case kickstart(label: String, restart: Bool)
  /// Unloads the job until the next login or registration. Stopping uses
  /// this, not SIGTERM: KeepAlive relaunches the helper however it exits,
  /// and only an unloaded job stays down.
  case bootout(label: String)
}

public struct LiveServiceSystem: ServiceSystem {
  private let client: ServiceClient

  public init(tokenFile: URL? = nil) {
    client = tokenFile.map(ServiceClient.init(tokenFile:)) ?? ServiceClient()
  }

  public func agentStatus(plistName: String) async -> AgentStatus {
    switch SMAppService.agent(plistName: plistName).status {
    case .enabled: .enabled
    case .requiresApproval: .requiresApproval
    default: .notRegistered
    }
  }

  public func job(label: String) async -> Job? {
    guard
      let result = try? await ProcessRunner.run(
        "/bin/launchctl", arguments: ["print", Self.target(label)]),
      result.exitCode == 0
    else { return nil }
    return Job(launchctlPrint: result.output)
  }

  public func diagnose(endpoint: URL) async -> DiagnoseReply {
    await client.diagnose(endpoint: endpoint)
  }

  public func listeners(port: Int) async -> Set<Int32> {
    let result = try? await ProcessRunner.run(
      "/usr/sbin/lsof", arguments: ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-t"], timeout: 3)
    return Set((result?.output ?? "").components(separatedBy: .newlines).compactMap(Int32.init))
  }

  public func run(_ command: SystemCommand) async throws {
    switch command {
    case .register(let plistName):
      try SMAppService.agent(plistName: plistName).register()
    case .unregister(let plistName):
      try await SMAppService.agent(plistName: plistName).unregister()
    case .kickstart(let label, let restart):
      try await launchctl(["kickstart"] + (restart ? ["-k"] : []) + [Self.target(label)])
    case .bootout(let label):
      try await launchctl(["bootout", Self.target(label)])
    }
  }

  public func isOutdated(pid: Int32, executable: URL) async -> Bool {
    var file = stat()
    guard let started = Self.started(pid), stat(executable.path, &file) == 0 else { return false }
    // ctime, not mtime: ditto and cp -p keep the build's mtime, but a new
    // file always gets a new ctime.
    let replaced = file.st_ctimespec
    return (started.tv_sec, Int(started.tv_usec) * 1000) < (replaced.tv_sec, replaced.tv_nsec)
  }

  public func startTime(pid: Int32) async -> Date? {
    Self.started(pid).map {
      Date(timeIntervalSince1970: Double($0.tv_sec) + Double($0.tv_usec) / 1_000_000)
    }
  }

  private static func started(_ pid: Int32) -> timeval? {
    var info = kinfo_proc()
    var size = MemoryLayout<kinfo_proc>.stride
    var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
    guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
    return info.kp_proc.p_un.__p_starttime
  }

  public func requestContactsAccess() async -> PermissionStatus {
    _ = try? await CNContactStore().requestAccess(for: .contacts)
    return switch CNContactStore.authorizationStatus(for: .contacts) {
    case .authorized: .authorized
    case .limited: .limited
    case .denied: .denied
    case .restricted: .restricted
    default: .notDetermined
    }
  }

  public func requestHelperPermission(
    _ permission: SetupPermission, endpoint: URL, processID: Int32
  ) async throws -> SetupPermissionReply {
    try await client.requestPermission(
      endpoint: endpoint, permission: permission, expectedProcessID: processID)
  }

  public func pause() async {
    await withCheckedContinuation { continuation in
      DispatchQueue.global().asyncAfter(deadline: .now() + 0.35) { continuation.resume() }
    }
  }

  private static func target(_ label: String) -> String { "gui/\(getuid())/\(label)" }

  /// `kickstart -k` within 10 seconds of the helper's last launch blocks until
  /// the plist's ThrottleInterval has passed, so the wait must outlast it.
  private func launchctl(_ arguments: [String]) async throws {
    let result = try await ProcessRunner.run("/bin/launchctl", arguments: arguments, timeout: 15)
    guard result.exitCode == 0 else {
      throw CoreError.commandFailed(
        "macOS could not change the service. \(result.output.trimmingCharacters(in: .whitespacesAndNewlines))"
      )
    }
  }
}
