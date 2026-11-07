import Foundation
import IMessageMaxContract
import Testing

@testable import MaxCore

private var fm: FileManager { .default }

/// An app bundle with an Info.plist naming `identifier` and a file `marker`.
private func app(
  at url: URL, identifier: String = ServiceDefaults.companionBundleID, marker: String
) throws -> URL {
  let contents = url.appendingPathComponent("Contents")
  try fm.createDirectory(at: contents, withIntermediateDirectories: true)
  try PropertyListSerialization.data(
    fromPropertyList: ["CFBundleIdentifier": identifier], format: .xml, options: 0
  ).write(to: contents.appendingPathComponent("Info.plist"))
  try Data(marker.utf8).write(to: url.appendingPathComponent("marker"))
  return url
}

private func marker(_ app: URL) throws -> String {
  try String(contentsOf: app.appendingPathComponent("marker"), encoding: .utf8)
}

private struct Layout {
  let source: URL
  let applications: URL
  var target: URL { applications.appendingPathComponent("iMessage Max.app") }

  init() throws {
    let root = try temporaryHome()
    source = try app(at: root.appendingPathComponent("Downloads/iMessage Max.app"), marker: "new")
    applications = root.appendingPathComponent("Applications")
    try fm.createDirectory(at: applications, withIntermediateDirectories: true)
  }

  func entries() throws -> [String] { try fm.contentsOfDirectory(atPath: applications.path).sorted() }
}

@Test func movingTheAppReplacesAnOlderCopy() throws {
  let layout = try Layout()
  _ = try app(at: layout.target, marker: "old")
  var quit: [URL] = []
  let target = try AppMover.install(layout.source, into: layout.applications) { quit.append($0) }
  #expect(target.path == layout.target.path)
  #expect(quit.map(\.path) == [layout.target.path], "the running copy quits first")
  #expect(try marker(target) == "new")
  #expect(try layout.entries() == ["iMessage Max.app"])
}

@Test func movingIntoAnEmptyFolderQuitsNothing() throws {
  let layout = try Layout()
  let target = try AppMover.install(layout.source, into: layout.applications) { _ in
    Issue.record("nothing to quit")
  }
  #expect(try marker(target) == "new")
  #expect(try layout.entries() == ["iMessage Max.app"])
}

@Test func anotherAppWithTheSameNameIsNeverReplaced() throws {
  let layout = try Layout()
  _ = try app(at: layout.target, identifier: "com.example.other", marker: "theirs")
  #expect(throws: AppMover.Failure.otherApp(name: "iMessage Max.app")) {
    try AppMover.install(layout.source, into: layout.applications)
  }
  #expect(try marker(layout.target) == "theirs")
  #expect(try layout.entries() == ["iMessage Max.app"])
}

@Test func aFailedMoveKeepsTheOldCopyAndNoStagedCopy() throws {
  let layout = try Layout()
  _ = try app(at: layout.target, marker: "old")
  #expect(throws: AppMover.Failure.copyStillRunning) {
    try AppMover.install(layout.source, into: layout.applications) { _ in
      throw AppMover.Failure.copyStillRunning
    }
  }
  #expect(try marker(layout.target) == "old")
  #expect(try layout.entries() == ["iMessage Max.app"])

  let unreadable = layout.source.appendingPathComponent("Contents/locked")
  try Data("x".utf8).write(to: unreadable)
  try fm.setAttributes([.posixPermissions: 0], ofItemAtPath: unreadable.path)
  defer { try? fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: unreadable.path) }
  #expect(throws: (any Error).self) {
    try AppMover.install(layout.source, into: layout.applications)
  }
  #expect(try marker(layout.target) == "old", "a copy that fails partway changes nothing")
  #expect(try layout.entries() == ["iMessage Max.app"])
}

@Test func stagedCopiesFromACrashedMoveAreSwept() throws {
  let layout = try Layout()
  let stale = layout.applications.appendingPathComponent(
    AppMover.stagingPrefix(for: layout.target) + "crashed")
  _ = try app(at: stale, marker: "half")
  let unrelated = layout.applications.appendingPathComponent(".hidden")
  try Data().write(to: unrelated)
  _ = try AppMover.install(layout.source, into: layout.applications)
  #expect(try layout.entries() == [".hidden", "iMessage Max.app"])
}
