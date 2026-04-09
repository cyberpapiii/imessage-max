# Maintainer Notes — 2026-04-09

This note captures a few design choices that are correct for the current project shape, but easy to second-guess later if the context gets lost.

## 1. Tool Handler Registry Uses A Lock, Not An Actor

`ToolHandlerRegistry` in `swift/Sources/iMessageMax/Server/ServerExtensions.swift` is now a lock-guarded class instead of an actor.

Why:
- tool registration happens during startup
- handler lookup happens on tool calls
- the registration API is much simpler when it can stay synchronous

What to remember:
- this is safe because mutation is narrow and infrequent
- any future code that adds new mutation paths must keep using the same lock discipline
- if registry behavior becomes more dynamic later, revisiting an actor-based design may be worth it

## 2. Some Split Files Needed Slightly Wider Access

`GetMessages.swift` and `Search.swift` were split so the main files hold the public flow and the helper-heavy code lives in `GetMessagesInternals.swift` and `SearchInternals.swift`.

Why:
- the original files had become too dense to review and test comfortably
- the split keeps the outside behavior the same while making the internals easier to work in

What to remember:
- `db`, `resolver`, and `sessionGapNanoseconds` are no longer private-only because the extracted helper files need them
- this is a tradeoff in service of maintainability, not a signal that these should become general-purpose shared APIs

## 3. Database `@unchecked Sendable` Is Intentional

`Database` stays lightweight and uses connection-per-query access.

Why this is acceptable here:
- the object only stores the database path
- each call opens its own read-only SQLite connection
- there is no shared mutable connection state

What to remember:
- this design is a good fit for the current MCP workload
- if the server ever moves toward heavy concurrent query traffic, revisit the database access model before optimizing elsewhere

## 4. `make install` Is Intentionally Opinionated

The install flow now does more than just build:
- signs the binary
- restarts the launchd service
- verifies that the running server matches the new build
- reveals the binary in Finder to make Full Disk Access fixes easier

Why:
- this project lives in the messy reality of macOS permissions and local services
- a "smart" install command saves time and prevents stale-server confusion

What to remember:
- the longer verification loop is deliberate
- if this ever starts feeling too heavy, prefer adding a lighter alternate target rather than weakening the safe default

## 5. Search And Message Retrieval Now Depend On Fixture-Based Tests

The higher-risk tool behavior is now covered with temporary SQLite databases and seeded resolver data in the test target.

Why:
- it proves behavior without touching the real Messages database
- it keeps tests stable and repeatable

What to remember:
- when changing `search` or `get_messages`, update the fixtures and behavior tests together
- if a change only "works" against the live database and cannot be expressed in the fixture harness, that is a warning sign worth slowing down for
