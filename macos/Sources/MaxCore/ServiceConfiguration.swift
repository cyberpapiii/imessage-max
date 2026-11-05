import Foundation
import IMessageMaxContract

public struct ServiceConfiguration: Sendable {
  public static let label = ServiceDefaults.launchdLabel
  public let binary: URL
  public let endpoint: URL
  public let plist: URL
  public let isInstalled: Bool

  public init(data: Data?, home: URL) throws {
    plist = home.appendingPathComponent(ServiceDefaults.launchAgentPath)
    isInstalled = data != nil
    var host = ServiceDefaults.host
    var port = ServiceDefaults.port
    if let data {
      guard
        let values = try PropertyListSerialization.propertyList(from: data, format: nil)
          as? [String: Any],
        values["Label"] as? String == Self.label,
        let args = values["ProgramArguments"] as? [String], let executable = args.first,
        executable.hasPrefix("/"),
        URL(fileURLWithPath: executable).lastPathComponent == ServiceDefaults.executableName,
        args.contains(ServerOption.http.flag), values["Program"] == nil
      else { throw CoreError.invalidConfiguration }
      binary = URL(fileURLWithPath: executable)
      var index = 1
      var seen: Set<ServerOption> = []
      while index < args.count {
        let parts = args[index].split(
          separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        guard let option = ServerOption(flag: String(parts[0])),
          seen.insert(option).inserted
        else { throw CoreError.invalidConfiguration }
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
          case .http, .allowExternalBind: break
          }
        }
        index += 1
      }
      guard seen.contains(.http) else { throw CoreError.invalidConfiguration }
    } else {
      binary = home.appendingPathComponent(ServiceDefaults.helperInstallPath)
    }
    guard ServiceDefaults.loopbackHosts.contains(host) else {
      throw CoreError.invalidConfiguration
    }
    var url = URLComponents()
    url.scheme = "http"
    url.host = host == "::1" ? "[::1]" : host
    url.port = port
    url.path = "/"
    guard let endpoint = url.url else { throw CoreError.invalidConfiguration }
    self.endpoint = endpoint
  }

  public static func renderTemplate(_ template: Data, binary: URL, home: URL) throws -> Data {
    guard
      var plist = try PropertyListSerialization.propertyList(from: template, format: nil)
        as? [String: Any],
      plist["Label"] as? String == label,
      var args = plist["ProgramArguments"] as? [String], args.first == "__BIN__"
    else {
      throw CoreError.invalidConfiguration
    }
    args[0] = binary.path
    plist["ProgramArguments"] = args
    for key in ["StandardErrorPath", "StandardOutPath"] {
      if let path = plist[key] as? String, path.hasPrefix("~/") {
        plist[key] = home.appendingPathComponent(String(path.dropFirst(2))).path
      }
    }
    return try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
  }
}
