# Maintainer notes, 2026-04-09

This note records a few design choices that are right for the project as it is today but easy to second-guess later without the context.

## 1. The tool catalog is immutable

The server builds `ToolCatalog` (`swift/Sources/iMessageMax/Server/ToolCatalog.swift`) once at startup and hands it to every lane: legacy stdio, legacy HTTP sessions, and the modern dispatcher. It is `@unchecked Sendable` because it holds only `let` properties after `init`.

What to remember:
- to add a tool, add a `ToolDefinition` to the catalog's list; nothing registers tools later
- two tools with the same name stop the process at startup, so the server never advertises a tool that never runs

## 2. Some split files needed slightly wider access

`GetMessages.swift` and `Search.swift` were split. The main files hold the public flow, and the helper code lives in `GetMessagesInternals.swift` and `SearchInternals.swift`.

Why:
- the original files had become too dense to review and test comfortably
- the split keeps the outside behavior the same and makes the internals easier to work in

What to remember:
- `db`, `resolver`, and `sessionGapNanoseconds` are no longer private, because the extracted helper files need them
- this is a tradeoff for maintainability, not a sign that they should become general-purpose shared APIs

## 3. Database `@unchecked Sendable` is intentional

`Database` is a small type that opens one connection per query.

Why this is acceptable here:
- the object only stores the database path
- each call opens its own read-only SQLite connection
- there is no shared mutable connection state

What to remember:
- this design fits the current MCP workload
- if the server ever moves toward heavy concurrent query traffic, revisit the database access model before optimizing elsewhere

## 4. `make install` is intentionally opinionated

The install flow does more than build:
- signs the binary
- restarts the launchd service
- verifies that the running server matches the new build
- checks that the running server can read chat.db, and prints the `open -R` command for the Full Disk Access fix when it cannot

Why:
- this project has to deal with macOS permissions and local services
- an install command that does these checks saves time and avoids confusion from a stale server

What to remember:
- the longer verification loop is deliberate
- if this ever feels too heavy, add a lighter separate target instead of weakening the safe default

## 5. Search and message retrieval depend on fixture-based tests

Tests for the higher-risk tool behavior use temporary SQLite databases and seeded resolver data in the test target.

Why:
- they prove behavior without touching the real Messages database
- they keep tests stable and repeatable

What to remember:
- when changing `search` or `get_messages`, update the fixtures and behavior tests together
- if a change only "works" against the live database and the fixture tests cannot express it, slow down and find out why
