import Foundation

public struct ServiceConfiguration: Sendable {
  public static let label = "local.imessage-max"
  public let binary: URL
  public let endpoint: URL
  public let plist: URL
  public let isInstalled: Bool

  public init(data: Data?, home: URL) throws {
    plist = home.appendingPathComponent("Library/LaunchAgents/\(Self.label).plist")
    isInstalled = data != nil
    var host = "127.0.0.1"
    var port = 8080
    if let data {
      guard
        let values = try PropertyListSerialization.propertyList(from: data, format: nil)
          as? [String: Any],
        values["Label"] as? String == Self.label,
        let args = values["ProgramArguments"] as? [String], let executable = args.first,
        executable.hasPrefix("/"),
        URL(fileURLWithPath: executable).lastPathComponent == "imessage-max",
        args.contains("--http"), values["Program"] == nil
      else { throw CoreError.invalidConfiguration }
      binary = URL(fileURLWithPath: executable)
      var index = 1
      var seen: Set<String> = []
      while index < args.count {
        let parts = args[index].split(
          separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
        let option = String(parts[0])
        guard seen.insert(option).inserted else { throw CoreError.invalidConfiguration }
        switch option {
        case "--http", "--allow-external-bind":
          guard parts.count == 1 else { throw CoreError.invalidConfiguration }
        case "--host", "--port", "--contacts-policy":
          let value: String
          if parts.count == 2 {
            value = String(parts[1])
          } else {
            index += 1
            guard args.indices.contains(index) else { throw CoreError.invalidConfiguration }
            value = args[index]
          }
          if option == "--host" {
            host = value
          } else if option == "--port" {
            guard let parsed = Int(value), (1...65535).contains(parsed) else {
              throw CoreError.invalidConfiguration
            }
            port = parsed
          } else if !["auto", "request", "skip"].contains(value) {
            throw CoreError.invalidConfiguration
          }
        default: throw CoreError.invalidConfiguration
        }
        index += 1
      }
      guard seen.contains("--http") else { throw CoreError.invalidConfiguration }
    } else {
      binary = home.appendingPathComponent(
        "Library/Application Support/iMessage Max/bin/imessage-max")
    }
    guard ["127.0.0.1", "localhost", "::1"].contains(host) else {
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
