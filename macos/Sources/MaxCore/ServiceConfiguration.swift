import Foundation
import IMessageMaxContract

/// The helper as this app bundles it, read from the one agent plist in
/// Contents/Library/LaunchAgents. A test build bundles another label and port,
/// so nothing here comes from ServiceDefaults except the checks.
public struct ServiceConfiguration: Sendable, Equatable {
  public let label: String
  public let bundleURL: URL
  public let endpoint: URL
  public let log: URL
  /// Only the released identity may touch an install of the old agent.
  public let isProduction: Bool

  public var plistName: String { "\(label).plist" }
  public var port: Int { endpoint.port ?? ServiceDefaults.port }
  public var helper: URL { bundleURL.appendingPathComponent(ServiceDefaults.helperBundlePath) }

  public static func load(
    bundle: Bundle = .main, home: URL = FileManager.default.homeDirectoryForCurrentUser
  ) throws -> ServiceConfiguration {
    let directory = bundle.bundleURL.appendingPathComponent(ServiceDefaults.agentPlistDirectory)
    let plists =
      (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?
      .filter { $0.pathExtension == "plist" } ?? []
    guard plists.count == 1, let identifier = bundle.bundleIdentifier else {
      throw CoreError.invalidConfiguration
    }
    return try ServiceConfiguration(
      plist: Data(contentsOf: plists[0]), plistName: plists[0].lastPathComponent,
      bundleIdentifier: identifier, bundleURL: bundle.bundleURL, home: home)
  }

  public init(plist data: Data, plistName: String, bundleIdentifier: String, bundleURL: URL, home: URL)
    throws
  {
    guard
      let values = try PropertyListSerialization.propertyList(from: data, format: nil)
        as? [String: Any],
      let label = values["Label"] as? String, plistName == "\(label).plist",
      values["BundleProgram"] as? String == ServiceDefaults.helperBundlePath,
      values["Program"] == nil,
      (values["AssociatedBundleIdentifiers"] as? [String])?.contains(bundleIdentifier) == true,
      let args = values["ProgramArguments"] as? [String], !args.isEmpty
    else { throw CoreError.invalidConfiguration }
    var host = ServiceDefaults.host
    var port = ServiceDefaults.port
    var log = home.appendingPathComponent(ServiceDefaults.logPath)
    var index = 1
    var seen: Set<ServerOption> = []
    while index < args.count {
      let parts = args[index].split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
      guard let option = ServerOption(flag: String(parts[0])), seen.insert(option).inserted else {
        throw CoreError.invalidConfiguration
      }
      if !option.takesValue {
        guard parts.count == 1 else { throw CoreError.invalidConfiguration }
      } else {
        let value: String
        if parts.count == 2 {
          value = String(parts[1])
        } else {
          index += 1
          guard args.indices.contains(index) else { throw CoreError.invalidConfiguration }
          value = args[index]
        }
        switch option {
        case .host: host = value
        case .port:
          guard let parsed = Int(value), (1...65535).contains(parsed) else {
            throw CoreError.invalidConfiguration
          }
          port = parsed
        case .contactsPolicy:
          guard ContactsPolicyOption(rawValue: value) != nil else {
            throw CoreError.invalidConfiguration
          }
        case .logFile:
          log =
            value.hasPrefix("~/")
            ? home.appendingPathComponent(String(value.dropFirst(2)))
            : URL(fileURLWithPath: value)
        case .http, .allowExternalBind: break
        }
      }
      index += 1
    }
    guard seen.contains(.http), ServiceDefaults.loopbackHosts.contains(host) else {
      throw CoreError.invalidConfiguration
    }
    var url = URLComponents()
    url.scheme = "http"
    url.host = host == "::1" ? "[::1]" : host
    url.port = port
    url.path = "/"
    guard let endpoint = url.url else { throw CoreError.invalidConfiguration }
    self.label = label
    self.bundleURL = bundleURL
    self.endpoint = endpoint
    self.log = log
    isProduction =
      label == ServiceDefaults.launchdLabel && bundleIdentifier == ServiceDefaults.companionBundleID
  }
}
