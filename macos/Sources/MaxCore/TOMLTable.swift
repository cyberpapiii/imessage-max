import Foundation

/// Just enough of TOML to find one table in a config file and edit its keys,
/// leaving every other byte as it was. It reads table headers and the extent
/// of each key's value, multi-line arrays and strings included. It never
/// rewrites a value it was not asked to change.
public struct TOMLTable: Sendable {
  public let path: [String]

  public init(_ path: String...) { self.path = path }

  /// The raw text of `key`'s value in this table, comment stripped. nil when
  /// the table or the key is missing.
  public func value(_ key: String, in text: String) -> String? {
    let document = Document(text)
    guard let table = document.tables.first(where: { $0.path == path && !$0.isArray }),
      let entry = table.entries.first(where: { $0.key == [key] })
    else { return nil }
    return document.value(of: entry)
  }

  /// Whether `text` has this table.
  public func exists(in text: String) -> Bool {
    Document(text).tables.contains { $0.path == path && !$0.isArray }
  }

  /// Sets `values` in this table, in order, and deletes `removing` keys and
  /// the `dropping` subtables. Keys already present keep their place. A
  /// missing table is appended at the end.
  public func upsert(
    _ text: String?, values: [(key: String, value: String)], removing: Set<String> = [],
    dropping subtables: Set<String> = []
  ) throws -> String {
    let text = text ?? ""
    let document = Document(text)
    let newline = text.contains("\r\n") ? "\r\n" : "\n"
    if document.reachesInto(path) { throw TOMLLayoutError() }
    let owned = Set(values.map(\.key))
    guard let table = document.tables.first(where: { $0.path == path }) else {
      var output = text
      if !output.isEmpty && !output.hasSuffix("\n") { output += newline }
      if !output.isEmpty && !output.hasSuffix("\n\n") && !output.hasSuffix("\r\n\r\n") {
        output += newline
      }
      output += "[\(path.map(Self.key).joined(separator: "."))]" + newline
      for (key, value) in values { output += "\(Self.key(key)) = \(value)" + newline }
      return output
    }
    if table.isArray { throw TOMLLayoutError() }
    var skip = Set<Int>()
    var replace: [Int: String] = [:]
    var placed = Set<String>()
    for entry in table.entries {
      guard let first = entry.key.first, owned.contains(first) || removing.contains(first) else {
        continue
      }
      skip.formUnion(entry.lines)
      if owned.contains(first), entry.key.count == 1, placed.insert(first).inserted,
        let value = values.first(where: { $0.key == first })?.value
      {
        replace[entry.lines.lowerBound] = "\(Self.key(first)) = \(value)"
      }
    }
    for value in values where !placed.contains(value.key) {
      // A key that was only present as dotted subkeys takes the place of
      // the first of them.
      if let entry = table.entries.first(where: { $0.key.first == value.key }) {
        replace[entry.lines.lowerBound] = "\(Self.key(value.key)) = \(value.value)"
        placed.insert(value.key)
      }
    }
    for sub in document.tables where sub.path.count > path.count && sub.path.starts(with: path) {
      if subtables.contains(sub.path[path.count]) {
        skip.formUnion(sub.header..<(sub.entries.last?.lines.upperBound ?? sub.header + 1))
      }
    }
    let missing = values.filter { !placed.contains($0.key) }
    let anchor = table.entries.last?.lines.upperBound ?? table.header + 1
    let lines = document.lines
    var output: [String] = []
    for index in lines.indices {
      if index == anchor {
        output += missing.map { "\(Self.key($0.key)) = \($0.value)" + (newline == "\r\n" ? "\r" : "") }
      }
      if let line = replace[index] {
        output.append(line + (lines[index].hasSuffix("\r") ? "\r" : ""))
      } else if !skip.contains(index) {
        output.append(lines[index])
      }
    }
    if anchor >= lines.count {
      // The table's last key is the file's last line, with no final newline.
      output += missing.map { "\(Self.key($0.key)) = \($0.value)" }
      if !missing.isEmpty { output.append("") }
    }
    return output.joined(separator: "\n")
  }

  /// A TOML basic string.
  public static func string(_ value: String) -> String {
    var escaped = ""
    for scalar in value.unicodeScalars {
      switch scalar {
      case "\"": escaped += "\\\""
      case "\\": escaped += "\\\\"
      case "\n": escaped += "\\n"
      case "\t": escaped += "\\t"
      case "\r": escaped += "\\r"
      case _ where scalar.value < 0x20 || scalar.value == 0x7F:
        escaped += String(format: "\\u%04X", scalar.value)
      default: escaped.unicodeScalars.append(scalar)
      }
    }
    return "\"\(escaped)\""
  }

  /// The string a single-line basic or literal string value holds.
  public static func decodeString(_ raw: String) -> String? {
    if raw.count >= 2, raw.hasPrefix("'"), raw.hasSuffix("'"), !raw.hasPrefix("'''") {
      return String(raw.dropFirst().dropLast())
    }
    guard raw.count >= 2, raw.hasPrefix("\""), raw.hasSuffix("\""), !raw.hasPrefix("\"\"\"") else {
      return nil
    }
    var result = ""
    var escaping = false
    for character in raw.dropFirst().dropLast() {
      if escaping {
        switch character {
        case "n": result.append("\n")
        case "t": result.append("\t")
        case "r": result.append("\r")
        default: result.append(character)
        }
        escaping = false
      } else if character == "\\" {
        escaping = true
      } else {
        result.append(character)
      }
    }
    return escaping ? nil : result
  }

  private static func key(_ key: String) -> String {
    key.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_" || $0 == "-") }
      && !key.isEmpty ? key : string(key)
  }
}

public struct TOMLLayoutError: Error, Sendable {}

/// A TOML file as lines, with each table's header and each key's lines.
private struct Document {
  struct Entry {
    var key: [String]
    var lines: Range<Int>
    /// Where the value starts on its first line.
    var valueStart: String.Index
  }

  struct Table {
    var path: [String]
    var isArray: Bool
    var header: Int
    var entries: [Entry] = []
  }

  let lines: [String]
  private(set) var root: [Entry] = []
  private(set) var tables: [Table] = []

  init(_ text: String) {
    lines = text.components(separatedBy: "\n")
    var scanner = Scanner()
    var index = 0
    while index < lines.count {
      let line = lines[index]
      let trimmed = line.drop { $0 == " " || $0 == "\t" }
      if trimmed.isEmpty || trimmed.hasPrefix("#") || trimmed.hasPrefix("\r") {
        index += 1
        continue
      }
      if trimmed.hasPrefix("[") {
        let isArray = trimmed.hasPrefix("[[")
        let inner = trimmed.dropFirst(isArray ? 2 : 1)
        if let (path, _) = Self.dottedKey(inner, until: "]") {
          tables.append(Table(path: path, isArray: isArray, header: index))
        }
        index += 1
        continue
      }
      guard let (key, rest) = Self.dottedKey(trimmed, until: "=") else {
        index += 1
        continue
      }
      let start = index
      scanner.scan(line[rest...])
      index += 1
      while scanner.open, index < lines.count {
        scanner.scan(lines[index][...])
        index += 1
      }
      scanner = Scanner()
      let entry = Entry(key: key, lines: start..<index, valueStart: rest)
      if tables.isEmpty { root.append(entry) } else { tables[tables.count - 1].entries.append(entry) }
    }
  }

  func value(of entry: Entry) -> String {
    let text = entry.lines.map { $0 == entry.lines.lowerBound ? String(lines[$0][entry.valueStart...]) : lines[$0] }
      .joined(separator: "\n")
    return Self.stripComment(text).trimmingCharacters(in: .whitespacesAndNewlines)
  }

  /// Whether a key outside `path`'s own table and subtables defines part of
  /// it, as `imessage = { … }` under the parent table does.
  func reachesInto(_ path: [String]) -> Bool {
    let scopes: [(prefix: [String], entries: [Entry])] =
      [([], root)] + tables.map { ($0.path, $0.entries) }
    return scopes.contains { scope in
      scope.prefix.count < path.count
        && scope.entries.contains { entry in
          let full = scope.prefix + entry.key
          return full.count >= path.count && Array(full.prefix(path.count)) == path
        }
    }
  }

  /// Parses `a."b".c` up to `terminator`, returning the segments and the
  /// index just past the terminator.
  private static func dottedKey(_ text: Substring, until terminator: Character)
    -> ([String], String.Index)?
  {
    var segments: [String] = []
    var current = ""
    var quote: Character?
    var quoted = false
    var index = text.startIndex
    while index < text.endIndex {
      let character = text[index]
      if let open = quote {
        if character == "\\" && open == "\"" {
          index = text.index(after: index)
          if index < text.endIndex { current.append(text[index]) }
        } else if character == open {
          quote = nil
        } else {
          current.append(character)
        }
      } else if character == "\"" || character == "'" {
        quote = character
        quoted = true
      } else if character == "." || character == terminator {
        let segment = quoted ? current : current.trimmingCharacters(in: .whitespaces)
        guard !segment.isEmpty || quoted else { return nil }
        segments.append(segment)
        current = ""
        quoted = false
        if character == terminator { return (segments, text.index(after: index)) }
      } else if character == " " || character == "\t" {
        if !current.isEmpty && !quoted { current.append(character) }
      } else {
        current.append(character)
      }
      index = text.index(after: index)
    }
    return nil
  }

  private static func stripComment(_ text: String) -> String {
    var scanner = Scanner()
    return text.components(separatedBy: "\n").map { line in
      let end = scanner.scan(line[...])
      return String(line[..<end])
    }.joined(separator: "\n")
  }
}

/// Tracks strings and brackets across lines, so a value that spans lines is
/// read as one value and a `#` inside a string is not a comment.
private struct Scanner {
  private enum Mode { case code, basic, literal, multiBasic, multiLiteral }
  private var mode = Mode.code
  private var depth = 0

  var open: Bool { depth > 0 || mode == .multiBasic || mode == .multiLiteral }

  /// Returns where a comment starts on this line, or the line's end.
  @discardableResult
  mutating func scan(_ line: Substring) -> String.Index {
    var index = line.startIndex
    if mode == .basic || mode == .literal { mode = .code }
    while index < line.endIndex {
      let character = line[index]
      let rest = line[index...]
      switch mode {
      case .code:
        if character == "#" { return index }
        if rest.hasPrefix("\"\"\"") {
          mode = .multiBasic
          index = line.index(index, offsetBy: 3)
          continue
        }
        if rest.hasPrefix("'''") {
          mode = .multiLiteral
          index = line.index(index, offsetBy: 3)
          continue
        }
        switch character {
        case "\"": mode = .basic
        case "'": mode = .literal
        case "[", "{": depth += 1
        case "]", "}": depth = max(0, depth - 1)
        default: break
        }
      case .basic:
        if character == "\\" {
          index = line.index(after: index)
        } else if character == "\"" {
          mode = .code
        }
      case .literal:
        if character == "'" { mode = .code }
      case .multiBasic:
        if character == "\\" {
          index = line.index(after: index)
        } else if rest.hasPrefix("\"\"\"") {
          mode = .code
          index = line.index(index, offsetBy: 3)
          continue
        }
      case .multiLiteral:
        if rest.hasPrefix("'''") {
          mode = .code
          index = line.index(index, offsetBy: 3)
          continue
        }
      }
      if index < line.endIndex { index = line.index(after: index) }
    }
    return line.endIndex
  }
}
