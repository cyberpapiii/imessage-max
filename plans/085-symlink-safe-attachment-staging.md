# Plan 085: Stage `send` attachments through a symlink-safe file handle into a 0700 directory

> **Executor instructions**: Follow this plan step by step. Run every
> verification command and confirm the expected result before moving to the
> next step. If anything in the "STOP conditions" section occurs, stop and
> report — do not improvise. When done, update the status row for this plan
> in `plans/README.md` — unless a reviewer dispatched you and told you they
> maintain the index.
>
> **Drift check (run first)**: `git diff --stat 42deb1f..HEAD -- swift/Sources/iMessageMax/Utilities/AppleScript.swift swift/Sources/iMessageMax/Utilities/SecurePath.swift swift/Sources/iMessageMax/Utilities/AttachmentSource.swift swift/Tests/iMessageMaxTests/AttachmentStagingSecurityTests.swift swift/Tests/iMessageMaxTests/AppleScriptRunnerValidationTests.swift swift/Tests/iMessageMaxTests/AppleScriptStagingTests.swift README.md`
> If any in-scope file changed since this plan was written, compare the
> "Current state" excerpts against the live code before proceeding; on a
> mismatch, treat it as a STOP condition.

## Status

- **Priority**: P1
- **Effort**: M
- **Risk**: MEDIUM (touches the only code path that hands a file to
  Messages.app; the existing staging tests pin the observable contract and
  must stay green unchanged)
- **Depends on**: none
- **Category**: security
- **Planned at**: commit `42deb1f`, 2026-09-02. Baseline: `cd swift && swift build && swift test` passes with 433 tests, 0 failures.

## Why this matters

`send` with `file_paths` is the one tool that moves bytes out of this Mac.
The caller is an LLM agent, and the path it passes is a string. Today that
string is validated with `FileManager.fileExists` / `isReadableFile` (both
follow symlinks) and then copied with `FileManager.copyItem` (path based).
Two consequences, both confirmed by a probe on this machine on 2026-09-02:

1. A symlink leaf is copied *as a symlink*. `copyItem` of `link -> secret`
   produces a staged entry of type `NSFileTypeSymbolicLink` whose contents
   read back as the secret. The AppleScript then tells Messages to send the
   staged path, and Messages follows the link. A symlink in a directory
   component (`~/Pictures/shared -> ~/.ssh`) is worse: `copyItem` silently
   copies the secret's bytes into staging as a regular file.
2. Validate-by-path then copy-by-path is a TOCTOU window. Between the
   `fileExists` check and the copy, a same-UID process (any other agent,
   any launchd job, anything running as this user) can replace the file
   with a link to `~/.ssh/id_rsa`, `~/Library/Keychains/*`, or a password
   manager database.

The threat model is the one the reference implementation (openclaw/imsg)
documents in `SecurePath.swift`: "a same-UID attacker who can write to our
RPC inbox could otherwise symlink an arbitrary file (a credential file, a
password manager DB)" and have Messages send it. For us the "RPC inbox" is
an MCP client talking to an HTTP server on `127.0.0.1:8080`; any local
process can send a `tools/call` for `send`. Rejecting symlinks anywhere in
the path, opening the source through `openat(O_NOFOLLOW)` walks, `fstat`ing
for `S_IFREG`, and copying from that already-open descriptor into a 0700
staging directory closes both holes with no dependency on the path string
after the open.

`plans/README.md` already records the direction ("Outbound `file_paths`
containment for `send`... today any readable path can be sent by an
agent"). This plan does the symlink and TOCTOU half. A directory allow-list
(only `~/Pictures`, `~/Downloads`, ...) is a policy question for the
operator and is deliberately left out; see Maintenance notes.

## Current state

### What is already in place (do not re-implement)

`swift/Sources/iMessageMax/Utilities/AppleScript.swift` (641 lines) already
has the shape of imsg's `MessageSender.stageAttachment`:

- Private per-send staging copy under `~/Pictures/imessage-max-staging/<UUID>/<original name>`
  (`stagingRootDirectory()` at `:434-438`, `prepareTrackedOutgoingFile` at `:261-286`).
- The AppleScript receives only the staged path: `sendFileToParticipant` /
  `sendFileToChat` (`:211-259`) run the script with
  `arguments: [handle, preparedFile.fileURL.path]`. The caller's path is
  never given to Messages.
- Cleanup on every exit of the send: `removeStagedDirectory` on handoff
  failure (`:224`, `:250`), on `finished`/`failed` transfer status
  (`waitForTransferCompletion` `:367-405`), a 30 s deferred removal on
  `pending`/`unknown` via `DispatchQueue.asyncAfter` (`scheduleDeferredStagedRemoval`,
  plan 050, no `Task.sleep`), and a 1-hour sweep of stale entries at the
  start of every send (`cleanupOldStagedFilesIfPossible` `:440-459`).
- `removeStagedDirectory` (`:424-432`) refuses to delete anything outside
  the staging root.
- Error scrubbing: `classifySendStderr` strips `/users/`, `/private/`,
  `/var/`, `imessage-max-staging` from anything returned to the client;
  `SendError.fileNotFound(name)` only ever carries a basename.
- Tilde expansion (`expandingTildeInPath`).

### What is missing (this plan)

| imsg protection | Present here? | Where it goes |
|---|---|---|
| Reject any symlink component (`lstat` walk, `S_IFLNK`) | No. `fileExists`/`isReadableFile` follow links | new `SecurePath.hasSymlinkComponent` |
| Trusted alias prefixes `/tmp`, `/var`, `/etc` → `/private/...` | No (not needed until the walk exists; `/tmp`, `/var`, `/etc` are symlinks on macOS and `FileManager.temporaryDirectory` is under `/var/folders`) | `SecurePath.absoluteLexicalPath` |
| Absolute path required | No. A relative path resolves against the process cwd (launchd's is `/`) | `SecurePath.absoluteLexicalPath` returns nil, `validateFilePath` throws |
| Open source via `openat(O_NOFOLLOW)` component walk, `fstat` must be `S_IFREG` | No | new `AttachmentSource.openFile(at:)` |
| Copy from the open descriptor (`fcopyfile`), never re-open by path | No. `copyItem(at:to:)` is path based | new `AttachmentSource.copy(_:to:)` |
| Destination created `O_CREAT|O_EXCL`, mode 0600 | No. `copyItem` preserves the source mode | `AttachmentSource.copy` |
| Staging directories mode 0700 | No. `createDirectory` default gives 0755 (probe: `755`) | `prepareTrackedOutgoingFile` |
| Root `resolvingSymlinksInPath()` + post-mkdir symlink re-check | No | `prepareTrackedOutgoingFile` |

Not present in either project and out of scope here: a size cap, a file
type allow-list, an outbound directory allow-list.

### The code being changed

`AppleScript.swift:261-286`:

```swift
    static func prepareTrackedOutgoingFile(
        sourcePath: String,
        existingOutgoingTransferStatuses: (String) throws -> [String] = queryOutgoingTransferStatuses
    ) throws -> PreparedOutgoingFile {
        cleanupOldStagedFilesIfPossible()

        let validatedPath = try validateFilePath(sourcePath)
        let sourceURL = URL(fileURLWithPath: validatedPath)
        let trackingName = sourceURL.lastPathComponent
        let existingOutgoingTransferCount = try existingOutgoingTransferStatuses(trackingName).count
        let stagedDirectory = stagingRootDirectory()
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        let stagedURL = stagedDirectory.appendingPathComponent(trackingName, isDirectory: false)

        try FileManager.default.createDirectory(at: stagedDirectory, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: sourceURL, to: stagedURL)

        return PreparedOutgoingFile(
            fileURL: stagedURL,
            trackingName: trackingName,
            existingOutgoingTransferCount: existingOutgoingTransferCount
        )
    }
```

`AppleScript.swift:309-320`:

```swift
    private static func validateFilePath(_ filePath: String) throws -> String {
        let expandedPath = (filePath as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: expandedPath, isDirectory: &isDirectory)
        guard exists, !isDirectory.boolValue else {
            throw SendError.fileNotFound((filePath as NSString).lastPathComponent)
        }
        guard FileManager.default.isReadableFile(atPath: expandedPath) else {
            throw SendError.fileNotFound((filePath as NSString).lastPathComponent)
        }
        return expandedPath
    }
```

`SendError` (`AppleScript.swift`, near the top): `fileNotFound(String)`
renders as `Could not read file at '<name>'.`; `invalidParams(String)`
renders its message verbatim. No other file switches exhaustively on
`SendError` (`grep -rn "case .fileNotFound" swift/Sources` → only
`AppleScript.swift`), so adding cases is safe but this plan adds none.

`PreparedOutgoingFile` (`:109-113`): `fileURL`, `trackingName`,
`existingOutgoingTransferCount`. Unchanged.

`stagingRootDirectory()` (`:434-438`):

```swift
    static func stagingRootDirectory() -> URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Pictures", isDirectory: true)
            .appendingPathComponent("imessage-max-staging", isDirectory: true)
    }
```

`Send.swift:273-275` documents `file_paths` as "Absolute or ~/expanded
local file path"; `SendPayload.build` only drops empty strings; the runner
is called at `Send.swift:486-505`. None of those change.

### Existing tests that pin the contract (must stay green, unedited)

`swift/Tests/iMessageMaxTests/AppleScriptRunnerValidationTests.swift`:

- `testSendFileToParticipantRejectsMissingFileBeforeAutomation`: path
  `/definitely/missing/file.png` must produce exactly
  `Could not read file at 'file.png'.` — ENOENT anywhere in the walk must
  still map to `SendError.fileNotFound(basename)`.
- `testPrepareTrackedOutgoingFileStagesInPicturesDirectoryWithOriginalName`:
  writes the source under `FileManager.default.temporaryDirectory`, which is
  `/var/folders/...`. `/var` is a symlink to `/private/var`. Without the
  alias table the new symlink walk would reject this path and break the
  test; with it the path becomes `/private/var/folders/...` and passes.
  Asserts the staged path contains `/Pictures/imessage-max-staging/` and
  ends with the original name.
- `testRemoveStagedDirectoryDeletesOnlyItsOwnDirectory`.

`swift/Tests/iMessageMaxTests/AppleScriptStagingTests.swift`:
`requireStagingRoot()` throws `XCTSkip` when `CI` is set and `~/Pictures`
is not writable; test dirs are prefixed `xctest-`; `tearDown` removes them.
Copy this helper's shape into the new test file rather than sharing it (the
helper is `private`).

`swift/Tests/iMessageMaxTests/AttachmentPathContainmentTests.swift` shows
the symlink-creation pattern with `XCTSkip` when
`createSymbolicLink` fails.

`swift/Tests/iMessageMaxTests/LaunchdSafetyTests.swift` scans
`swift/Sources` for `Task.sleep(`; nothing in this plan needs to wait.

### Reference implementation (openclaw/imsg, not visible to you)

`Sources/IMsgCore/SecurePath.swift`, the parts to port:

```swift
enum SecurePath {
  private static let trustedSystemAliasPrefixes: [(alias: String, canonical: String)] = [
    ("/tmp", "/private/tmp"),
    ("/var", "/private/var"),
    ("/etc", "/private/etc"),
  ]

  static func absoluteLexicalPath(_ path: String) -> String {
    normalizingTrustedSystemAliasPrefix((absoluteExpandedPath(path) as NSString).standardizingPath)
  }

  static func hasSymlinkComponent(_ path: String) -> Bool {
    let lexicalPath = absoluteLexicalPath(path)
    var cursor = ""
    for component in (lexicalPath as NSString).pathComponents {
      if component == "/" { cursor = "/"; continue }
      cursor = (cursor as NSString).appendingPathComponent(component)
      var info = stat()
      guard lstat(cursor, &info) == 0 else { continue }
      if (info.st_mode & S_IFMT) == S_IFLNK { return true }
    }
    return false
  }

  private static func normalizingTrustedSystemAliasPrefix(_ path: String) -> String {
    for (alias, canonical) in trustedSystemAliasPrefixes {
      if path == alias { return canonical }
      if path.hasPrefix(alias + "/") { return canonical + path.dropFirst(alias.count) }
    }
    return path
  }
}
```

(imsg's `absoluteExpandedPath` makes relative paths absolute against cwd;
we deliberately reject them instead, because our cwd under launchd is `/`
and an agent has no way to know it.)

`Sources/IMsgCore/AttachmentSource.swift`, the parts to port:

```swift
  static func openFile(at path: String) throws -> FileHandle {
    guard path.hasPrefix("/") else { throw AttachmentSourceError.invalidPath }
    var dirFD = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
    guard dirFD >= 0 else { throw errno error }
    defer { close(dirFD) }
    let components = (path as NSString).pathComponents.dropFirst()   // drop "/"
    guard let filename = components.last else { throw invalidPath }
    for component in components.dropLast() {
      let next = openat(dirFD, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
      guard next >= 0 else { throw errno error }
      close(dirFD)
      dirFD = next
    }
    let fd = openat(dirFD, filename, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
    guard fd >= 0 else { throw errno error }
    var info = stat()
    guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
      close(fd); throw AttachmentSourceError.notRegularFile
    }
    return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
  }

  static func copy(_ source: FileHandle, to destination: URL) throws {
    let destFD = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, S_IRUSR | S_IWUSR)
    guard destFD >= 0 else { throw errno error }
    defer { close(destFD) }
    guard fcopyfile(source.fileDescriptor, destFD, nil, copyfile_flags_t(COPYFILE_ALL)) == 0 else {
      throw errno error
    }
  }
```

Notes on the port: `openat` with `O_NOFOLLOW` on a symlink fails with
`ELOOP`; a component that is a regular file fails with `ENOTDIR`; a missing
component fails with `ENOENT`. `fcopyfile` is in `copyfile.h`, available
through `import Darwin` (Foundation re-exports it). Use `COPYFILE_DATA`
rather than `COPYFILE_ALL`: we do not want to copy the source's xattrs
(quarantine flags, Finder tags) or ACLs onto a file whose mode we just set
to 0600.

### Facts checked on this machine (2026-09-02)

- `/tmp -> private/tmp`, `/var -> private/var`, `/etc -> private/etc`.
- `FileManager.copyItem` of a symlink leaf yields `NSFileTypeSymbolicLink`
  with the target's contents readable; through a symlinked directory it
  yields `NSFileTypeRegular` with the target's bytes.
- `createDirectory(withIntermediateDirectories: true)` without attributes
  yields mode `755`.
- `fileExists` and `isReadableFile` both return true for a symlink to a
  readable file.

## Commands you will need

| Purpose | Command | Expected |
|---|---|---|
| Build | `cd swift && swift build` | `Build complete!` |
| Focused tests | `cd swift && swift test --filter "AttachmentStagingSecurityTests\|AppleScriptRunnerValidationTests\|AppleScriptStagingTests\|AttachmentPathContainmentTests\|LaunchdSafetyTests"` | 0 failures |
| Whole suite | `cd swift && swift test` | 433 plus the new tests, 0 failures |
| Perms of a staged dir | `stat -f '%Lp' <dir>` | `700` |
| Leftovers | `ls ~/Pictures/imessage-max-staging/` | no `xctest-*` or stray UUID dirs after tests |

## Scope

**In scope** (the only files you should modify or create):

- `swift/Sources/iMessageMax/Utilities/SecurePath.swift` (create)
- `swift/Sources/iMessageMax/Utilities/AttachmentSource.swift` (create)
- `swift/Sources/iMessageMax/Utilities/AppleScript.swift` (`validateFilePath`, `prepareTrackedOutgoingFile` only)
- `swift/Tests/iMessageMaxTests/AttachmentStagingSecurityTests.swift` (create)
- `README.md` (`### send` section, one paragraph)

**Out of scope** (do NOT touch):

- `AppleScriptRunnerValidationTests.swift`, `AppleScriptStagingTests.swift`,
  `AttachmentPathContainmentTests.swift`: must pass unedited. If one fails,
  the change is wrong, not the test.
- `Send.swift`, `SendPayload.swift`, `SendResolution.swift`: the tool
  contract (`file_paths` schema text, dispatch) does not change.
- `AttachmentPathPolicy.swift`: that is inbound containment for chat.db
  attachment paths and uses `resolvingSymlinksInPath` on purpose.
- The staging root location, the 30 s deferred removal, the 1-hour sweep,
  `removeStagedDirectory`, `classifySendStderr`, `waitForTransferCompletion`.
- Size caps, type allow-lists, directory allow-lists.
- `CHANGELOG.md`, `.mcp.json`, anything under `swift/launchd`.
- `Task.sleep` under `swift/Sources` (never).

## Git workflow

- Branch: `git checkout -b advisor/085-symlink-safe-attachment-staging main`
- Conventional commits:
  - Commit 1 (after Step 2): `feat(send): add SecurePath lexical normalization and symlink walk`
  - Commit 2 (after Step 4): `feat(send): stage attachments through a symlink-safe file handle into a 0700 directory`
  - Commit 3 (after Step 5): `docs: describe send attachment path rules`
- Do not push, do not merge, do not tag.

## Steps

### Step 1: SecurePath tests first (red)

Create `swift/Tests/iMessageMaxTests/AttachmentStagingSecurityTests.swift`.
Start with the pure-function tests (no filesystem):

```swift
import Foundation
import XCTest
@testable import iMessageMax

final class AttachmentStagingSecurityTests: XCTestCase {
    func testAliasPrefixesNormalizeToPrivate() {
        XCTAssertEqual(SecurePath.absoluteLexicalPath("/tmp/x.png"), "/private/tmp/x.png")
        XCTAssertEqual(SecurePath.absoluteLexicalPath("/var/folders/a/b.png"), "/private/var/folders/a/b.png")
        XCTAssertEqual(SecurePath.absoluteLexicalPath("/etc/hosts"), "/private/etc/hosts")
        XCTAssertEqual(SecurePath.absoluteLexicalPath("/tmp"), "/private/tmp")
        XCTAssertEqual(SecurePath.absoluteLexicalPath("/tmpfoo/x"), "/tmpfoo/x")       // prefix must be a whole component
        XCTAssertEqual(SecurePath.absoluteLexicalPath("/private/tmp/x"), "/private/tmp/x") // idempotent
    }

    func testTildeAndDotSegmentsAreResolvedLexically() {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        XCTAssertEqual(SecurePath.absoluteLexicalPath("~/Pictures/../Downloads/a.png"), home + "/Downloads/a.png")
    }

    func testRelativePathsAreNotAbsolutized() {
        XCTAssertNil(SecurePath.absoluteLexicalPath("Pictures/a.png"))
        XCTAssertNil(SecurePath.absoluteLexicalPath("./a.png"))
        XCTAssertNil(SecurePath.absoluteLexicalPath(""))
    }
}
```

**Verify**: `cd swift && swift build --build-tests` fails with
`cannot find 'SecurePath' in scope`. Expected red.

### Step 2: SecurePath

Create `swift/Sources/iMessageMax/Utilities/SecurePath.swift`:

```swift
import Foundation

/// Lexical path normalization plus a symlink walk for outbound attachment
/// paths. `realpath()` is not enough: it resolves the link and hands back
/// the target, which is exactly what an attacker wants. We refuse the path
/// on any symlink instead. Ported from openclaw/imsg.
enum SecurePath {
    /// macOS keeps these as symlinks to /private/*. They are trusted, so
    /// rewrite them before the walk instead of rejecting them.
    private static let trustedSystemAliasPrefixes: [(alias: String, canonical: String)] = [
        ("/tmp", "/private/tmp"),
        ("/var", "/private/var"),
        ("/etc", "/private/etc"),
    ]

    /// Tilde-expanded, `..`/`.`-collapsed, alias-normalized absolute path.
    /// Nil when the input is not absolute after tilde expansion: we never
    /// resolve against the process cwd (under launchd it is `/`).
    static func absoluteLexicalPath(_ path: String) -> String? {
        let expanded = (path as NSString).expandingTildeInPath
        guard expanded.hasPrefix("/") else { return nil }
        let standardized = (expanded as NSString).standardizingPath
        return normalizingTrustedSystemAliasPrefix(standardized)
    }

    /// True when any component of the (already lexical) path is a symlink.
    /// Components that fail `lstat` are skipped; a missing file is a
    /// different error and is reported by the open that follows.
    static func hasSymlinkComponent(_ lexicalPath: String) -> Bool {
        var cursor = ""
        for component in (lexicalPath as NSString).pathComponents {
            if component == "/" { cursor = "/"; continue }
            cursor = (cursor as NSString).appendingPathComponent(component)
            var info = stat()
            guard lstat(cursor, &info) == 0 else { continue }
            if (info.st_mode & S_IFMT) == S_IFLNK { return true }
        }
        return false
    }

    private static func normalizingTrustedSystemAliasPrefix(_ path: String) -> String {
        for (alias, canonical) in trustedSystemAliasPrefixes {
            if path == alias { return canonical }
            if path.hasPrefix(alias + "/") { return canonical + path.dropFirst(alias.count) }
        }
        return path
    }
}
```

Note: `standardizingPath` on an absolute path does NOT resolve symlinks
(that is `resolvingSymlinksInPath`), which is what we want. It does strip
`/private` from `/private/tmp`-style paths only for `~`-relative inputs on
some Foundation versions; the `testAliasPrefixesNormalizeToPrivate`
idempotence case guards that. If that assertion fails, apply the alias
normalization after `standardizingPath` (as written) and also before it.

**Verify**: `cd swift && swift test --filter AttachmentStagingSecurityTests` → 3 tests, 0 failures. Commit 1.

### Step 3: Staging tests first (red)

Add to the same test file. Shared scaffolding, copied from
`AppleScriptStagingTests`:

```swift
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("xctest-085-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
        // Any staged dir this test created lives under the staging root; remove those we know about.
        for url in stagedToClean { try? FileManager.default.removeItem(at: url) }
    }
    private var stagedToClean: [URL] = []

    private func requireStagingRoot() throws {
        let root = AppleScriptRunner.stagingRootDirectory()
        if ProcessInfo.processInfo.environment["CI"] != nil,
           !FileManager.default.isWritableFile(atPath: root.deletingLastPathComponent().path) {
            throw XCTSkip("~/Pictures is not writable on this runner")
        }
    }

    private func makeSecret() throws -> URL {
        let secret = scratch.appendingPathComponent("id_rsa")
        try "SECRET".data(using: .utf8)!.write(to: secret)
        return secret
    }

    private func symlink(_ link: URL, to target: URL) throws {
        do { try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target) }
        catch { throw XCTSkip("cannot create symlinks here: \(error)") }
    }

    private static let finished: (String) throws -> [String] = { _ in ["finished"] }
```

`stagingRootDirectory()` is `private static` at `42deb1f`
(`AppleScript.swift:434`). Step 4 makes it internal; until then this
helper will not compile, which is part of the expected red.

Tests:

1. `testSymlinkLeafIsRejectedWithoutStaging`:
   `link = scratch/photo.png -> secret`; call
   `AppleScriptRunner.prepareTrackedOutgoingFile(sourcePath: link.path, existingOutgoingTransferStatuses: Self.finished)`
   inside `XCTAssertThrowsError`; assert `error is SendError`, the
   `localizedDescription` (or `"\(error)"`, whichever the runner uses for
   client text; see `SendError` at the top of `AppleScript.swift`) contains
   `symbolic link` and contains `'photo.png'` and does NOT contain
   `scratch.path`; and count entries under the staging root before/after:
   unchanged.
2. `testSymlinkDirectoryComponentIsRejected`:
   `realDir = scratch/real` containing `a.png`; `scratch/alias -> realDir`;
   sending `scratch/alias/a.png` throws the same class of error.
3. `testTmpAliasIsAccepted`: `try requireStagingRoot()`; write `a.png`
   under `scratch` (which is under `/var/folders`, i.e. behind the `/var`
   alias) and ALSO under `/tmp/xctest-085-<uuid>/a.png`; both stage
   successfully; append the staged parent directories to `stagedToClean`.
4. `testStagedCopyIsIndependentOfSource`: stage `a.png` containing
   `"ORIGINAL"`; then overwrite the source with `"CHANGED"` and finally
   replace the source with a symlink to a secret; read the staged file:
   still `"ORIGINAL"`; `attributesOfItem(atPath: staged)[.type] == FileAttributeType.typeRegular`.
5. `testStagingDirectoriesAre0700`: stage a file; assert
   `attributesOfItem(atPath: stagedDir)[.posixPermissions] as? Int == 0o700`
   for the per-send dir AND for `stagingRootDirectory()`; assert the staged
   file itself is `0o600`.
6. `testRelativePathIsRejected`: `prepareTrackedOutgoingFile(sourcePath: "Pictures/a.png", ...)`
   throws `SendError.invalidParams` whose text contains `absolute`.
7. `testNonRegularFileIsRejected`: `sourcePath: "/dev/null"` throws; text
   contains `regular file`. (`/dev/null` is a character device; the
   `openat` succeeds and `fstat` reports `S_IFCHR`.)
8. `testMissingFileStillReportsBasenameOnly`: `sourcePath: scratch.path + "/nope/missing.png"`
   throws with text exactly `Could not read file at 'missing.png'.`
   (this is the same wording `testSendFileToParticipantRejectsMissingFileBeforeAutomation`
   pins; ENOENT on a component and on the leaf must both map here).

**Verify**: `cd swift && swift test --filter AttachmentStagingSecurityTests`
→ tests 1, 2, 4 (symlink stage), 5, 6, 7 fail; 3 and 8 pass. Expected red.

### Step 4: AttachmentSource and the staging rewrite

Create `swift/Sources/iMessageMax/Utilities/AttachmentSource.swift`:

```swift
import Foundation

/// Opens an outbound attachment without following symlinks and copies it
/// from the open descriptor, so nothing after the open depends on the path
/// string. Ported from openclaw/imsg.
enum AttachmentSource {
    enum Failure: Error {
        case notAbsolute
        case notFound          // ENOENT / ENOTDIR on a component
        case notPermitted      // EACCES / EPERM
        case symlink           // ELOOP from O_NOFOLLOW
        case notRegularFile
        case other(Int32)
    }

    static func openFile(at path: String) throws -> FileHandle {
        guard path.hasPrefix("/") else { throw Failure.notAbsolute }
        var dirFD = open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard dirFD >= 0 else { throw Failure.other(errno) }
        defer { close(dirFD) }

        let components = Array((path as NSString).pathComponents.dropFirst())
        guard let filename = components.last, !filename.isEmpty else { throw Failure.notFound }

        for component in components.dropLast() {
            let next = openat(dirFD, component, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            guard next >= 0 else { throw map(errno) }
            close(dirFD)
            dirFD = next
        }

        let fd = openat(dirFD, filename, O_RDONLY | O_NONBLOCK | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw map(errno) }

        var info = stat()
        guard fstat(fd, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG else {
            close(fd)
            throw Failure.notRegularFile
        }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    /// Creates `destination` exclusively with mode 0600 and copies data only
    /// (no xattrs/ACLs: quarantine flags and Finder tags stay behind).
    static func copy(_ source: FileHandle, to destination: URL) throws {
        let destFD = open(destination.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard destFD >= 0 else { throw map(errno) }
        defer { close(destFD) }
        guard fcopyfile(source.fileDescriptor, destFD, nil, copyfile_flags_t(COPYFILE_DATA)) == 0 else {
            throw map(errno)
        }
    }

    private static func map(_ code: Int32) -> Failure {
        switch code {
        case ENOENT, ENOTDIR: return .notFound
        case EACCES, EPERM: return .notPermitted
        case ELOOP: return .symlink
        default: return .other(code)
        }
    }
}
```

Note on `defer { close(dirFD) }` with `dirFD` reassigned in the loop: the
defer closes whatever `dirFD` holds at exit, and the loop closes the
previous one before reassigning, so no descriptor leaks. If the compiler
warns about capturing a `var` in `defer`, that is fine.

Then in `AppleScript.swift` replace `validateFilePath` (`:309-320`) with a
function that returns both the lexical path and the open handle:

```swift
    /// Lexically absolutize, refuse symlinks anywhere in the path, then open
    /// the file without following links and confirm it is a regular file.
    /// Error text never contains the caller's path, only the basename.
    private static func openValidatedSource(_ filePath: String) throws -> (path: String, handle: FileHandle) {
        let basename = (filePath as NSString).lastPathComponent
        guard let lexical = SecurePath.absoluteLexicalPath(filePath) else {
            throw SendError.invalidParams("Attachment path for '\(basename)' must be absolute (or start with ~/).")
        }
        if SecurePath.hasSymlinkComponent(lexical) {
            throw SendError.invalidParams("Attachment '\(basename)' is or is behind a symbolic link; pass the real path.")
        }
        do {
            return (lexical, try AttachmentSource.openFile(at: lexical))
        } catch AttachmentSource.Failure.symlink {
            throw SendError.invalidParams("Attachment '\(basename)' is or is behind a symbolic link; pass the real path.")
        } catch AttachmentSource.Failure.notRegularFile {
            throw SendError.invalidParams("Attachment '\(basename)' must be a regular file.")
        } catch AttachmentSource.Failure.notAbsolute {
            throw SendError.invalidParams("Attachment path for '\(basename)' must be absolute (or start with ~/).")
        } catch {
            // notFound, notPermitted, other: same client-facing wording as before.
            throw SendError.fileNotFound(basename)
        }
    }
```

and rewrite `prepareTrackedOutgoingFile` (`:261-286`) so the copy goes
through the handle and every directory is 0700:

```swift
    static func prepareTrackedOutgoingFile(
        sourcePath: String,
        existingOutgoingTransferStatuses: (String) throws -> [String] = queryOutgoingTransferStatuses
    ) throws -> PreparedOutgoingFile {
        cleanupOldStagedFilesIfPossible()

        let (validatedPath, sourceHandle) = try openValidatedSource(sourcePath)
        defer { try? sourceHandle.close() }

        let trackingName = (validatedPath as NSString).lastPathComponent
        let existingOutgoingTransferCount = try existingOutgoingTransferStatuses(trackingName).count

        let root = stagingRootDirectory()
        let ownerOnly: [FileAttributeKey: Any] = [.posixPermissions: 0o700]
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: ownerOnly)
        try FileManager.default.setAttributes(ownerOnly, ofItemAtPath: root.path)   // pre-existing 0755 roots
        guard !SecurePath.hasSymlinkComponent(root.path) else {
            throw SendError.invalidParams("Attachment staging directory is behind a symbolic link.")
        }

        let stagedDirectory = root.appendingPathComponent(UUID().uuidString, isDirectory: true)
        let stagedURL = stagedDirectory.appendingPathComponent(trackingName, isDirectory: false)
        try FileManager.default.createDirectory(at: stagedDirectory, withIntermediateDirectories: false, attributes: ownerOnly)

        let prepared = PreparedOutgoingFile(
            fileURL: stagedURL,
            trackingName: trackingName,
            existingOutgoingTransferCount: existingOutgoingTransferCount
        )
        do {
            try AttachmentSource.copy(sourceHandle, to: stagedURL)
        } catch {
            removeStagedDirectory(for: prepared)
            throw SendError.fileNotFound(trackingName)
        }
        return prepared
    }
```

`removeStagedDirectory(for:)` (`:424`) takes a `PreparedOutgoingFile`, which
is why `prepared` is built before the copy. `stagingRootDirectory()` is
`private static` today (`:434`); drop `private` so the new tests can locate
the root (the staging tests in `AppleScriptStagingTests` compute the path
by hand instead; either is fine, but the tests below call the function).

The root check is a plain `hasSymlinkComponent(root.path)`; the home
directory is not an alias prefix. `~/Pictures` on a stock Mac is a real
directory; if an operator has symlinked it elsewhere the send fails
with a clear message rather than staging into a location we did not pick.
That is intentional; record it in the README paragraph.

Keep `removeStagedDirectory(for:)`'s signature as it is.

`createDirectory(... attributes: [.posixPermissions: 0o700])` applies the
mode to the created directory; with `withIntermediateDirectories: true` it
also applies to intermediates it creates. `~/Pictures` already exists so
its mode is untouched. `setAttributes` on the root is what fixes a root
created as 0755 by an earlier build.

**Verify**:
- `cd swift && swift build` → `Build complete!` (no new warnings about
  `Sendable`; these are all static functions on enums).
- `cd swift && swift test --filter "AttachmentStagingSecurityTests\|AppleScriptRunnerValidationTests\|AppleScriptStagingTests\|AttachmentPathContainmentTests\|LaunchdSafetyTests"`
  → 0 failures. In particular
  `testPrepareTrackedOutgoingFileStagesInPicturesDirectoryWithOriginalName`
  (source under `/var/folders`) and
  `testSendFileToParticipantRejectsMissingFileBeforeAutomation`
  (`Could not read file at 'file.png'.`) pass unedited.
- `stat -f '%Lp' ~/Pictures/imessage-max-staging` → `700`.
- `ls ~/Pictures/imessage-max-staging` → empty (tests cleaned up).

Commit 2.

### Step 5: README

In `README.md` under `### send` (`:344-357`) add one paragraph after the
`file_paths` description:

"Attachment paths must be absolute (or start with `~/`). The path is
checked component by component and refused if any part of it is a symbolic
link (`/tmp`, `/var`, `/etc` are allowed and read as `/private/...`). The
file is opened without following links, must be a regular file, and is
copied from that open handle into a private `0700` directory under
`~/Pictures/imessage-max-staging/`; Messages only ever sees the copy. If
`~/Pictures` itself is a symlink on your Mac, `send` with a file will refuse
to stage until it points at a real directory."

**Verify**: `grep -c "symbolic link" README.md` → at least 1.
`cd swift && swift build && swift test` → 433 + 11 = 444 tests, 0 failures.
Commit 3.

### Step 6: Manual check against Messages (optional, operator's Mac only)

Only if you are on the operator's Mac with Automation granted (the
validation tests stub the runner; this is the real path). From `swift/`
after `swift build`:

```
mkdir -p /tmp/085 && echo hi > /tmp/085/real.txt && ln -sf /tmp/085/real.txt /tmp/085/link.txt
```

Then through any MCP client call `send` with
`{"to": "<your own handle>", "file_paths": ["/tmp/085/link.txt"]}` →
error text `Attachment 'link.txt' is or is behind a symbolic link; pass the real path.`
and nothing new under `~/Pictures/imessage-max-staging`. Then with
`/tmp/085/real.txt` → the message arrives with `real.txt` attached and the
staging dir is gone within ~30 s. `rm -rf /tmp/085`.

## Test plan

- 3 pure `SecurePath` tests (alias table incl. non-component prefix and
  idempotence; tilde and `..`; relative inputs return nil).
- 8 staging tests: symlink leaf rejected with no staging side effect and no
  path leak; symlink directory component rejected; `/tmp` and `/var`
  alias paths accepted; staged copy independent of the source after
  overwrite and after replacing the source with a link, and is a regular
  file; per-send dir and root are 0700, staged file 0600; relative path
  rejected; `/dev/null` rejected as not regular; missing file keeps
  `Could not read file at 'missing.png'.`.
- Existing `AppleScriptRunnerValidationTests`, `AppleScriptStagingTests`,
  `AttachmentPathContainmentTests`, `SendToolExecuteTests` unchanged and
  green.
- `LaunchdSafetyTests` green.

## Done criteria

- [ ] `grep -n "copyItem\|isReadableFile\|fileExists(atPath: expandedPath" swift/Sources/iMessageMax/Utilities/AppleScript.swift` prints nothing inside `prepareTrackedOutgoingFile` / the validation helper (other uses elsewhere in the file, if any, are fine).
- [ ] `grep -n "O_NOFOLLOW" swift/Sources/iMessageMax/Utilities/AttachmentSource.swift` → 2 matches (directory walk and leaf).
- [ ] `grep -n "0o700" swift/Sources/iMessageMax/Utilities/AppleScript.swift` → at least 1.
- [ ] `grep -rn "Task.sleep(" swift/Sources` prints nothing.
- [ ] `git diff main -- swift/Tests/iMessageMaxTests/AppleScriptRunnerValidationTests.swift swift/Tests/iMessageMaxTests/AppleScriptStagingTests.swift swift/Sources/iMessageMax/Tools/Send.swift` is empty.
- [ ] `cd swift && swift test` reports 444 tests, 0 failures.
- [ ] `ls ~/Pictures/imessage-max-staging` is empty after the suite.
- [ ] Three commits on `advisor/085-symlink-safe-attachment-staging`, not pushed.
- [ ] `plans/README.md` row added/updated.

## STOP conditions

- The drift check shows in-scope changes and the excerpts no longer match.
- `testPrepareTrackedOutgoingFileStagesInPicturesDirectoryWithOriginalName`
  fails after Step 4. Most likely the alias normalization is not applied
  (source is under `/var/folders`). Report; do not edit the test.
- `testSendFileToParticipantRejectsMissingFileBeforeAutomation` fails with
  different wording. Report the exact string produced.
- `fcopyfile`, `copyfile_flags_t`, or `COPYFILE_DATA` do not resolve with
  `import Foundation`. Try `import Darwin` at the top of
  `AttachmentSource.swift`; if still unresolved, STOP and report rather
  than falling back to `FileHandle.readDataToEndOfFile()` (that would load
  the whole attachment into memory).
- Swift 6 rejects `FileHandle` returned from a static function or the
  `defer { close(dirFD) }` pattern with an error (not a warning). Report
  the diagnostic.
- `~/Pictures` on the executing machine is itself a symlink and the suite
  cannot stage anything. Report; do not weaken the root check.
- Any file outside the Scope list needs an edit to compile.

## Maintenance notes

- Still open, by design: an outbound directory allow-list (only stage from
  `~/Pictures`, `~/Downloads`, `~/Desktop`, `/tmp`, ...), a size cap, and a
  type allow-list. All three are operator policy and belong in one plan
  with a `--send-allow-dir` style flag and a `diagnose` capability entry.
  The `openValidatedSource` function is the single place to add them.
- `COPYFILE_DATA` deliberately drops xattrs. If an operator ever needs the
  `com.apple.quarantine` flag or Finder tags to travel with the attachment,
  switch to `COPYFILE_ALL` and re-run `testStagingDirectoriesAre0700`
  (the mode assertion on the staged file would need revisiting since
  `COPYFILE_STAT` copies the source mode).
- The symlink walk uses `lstat` before the `openat` walk. The `lstat` pass
  is what produces the friendly "is or is behind a symbolic link" message;
  the `O_NOFOLLOW` open is what makes it safe (a link swapped in between
  the two passes fails with `ELOOP` and maps to the same message). Do not
  remove either.
- `hasSymlinkComponent` skips components that fail `lstat`. A missing
  intermediate therefore reaches `openat`, which reports `ENOENT` and maps
  to `fileNotFound`. That is why the missing-file wording is unchanged.
- The 0700 mode is applied to the root on every send (`setAttributes`).
  It is one `chmod`; if the sweep ever moves to a background timer, move
  the chmod there too.
- Related upstream: openclaw/imsg `SecurePath.swift`, `AttachmentSource.swift`,
  `MessageSender.stageAttachment`. imsg stages under
  `~/Library/Messages/Attachments/imsg`; we keep `~/Pictures` because that
  location was chosen in plan 050 for Messages' sandbox and Photos-picker
  behaviour. Do not move it in this plan.
