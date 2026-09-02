# Changelog

## 1.5.0

Breaking for the install base: the deployment floor is **macOS 15** (Homebrew `:sequoia`), Swift tools-version 6.3, and dependencies were bumped (hummingbird 2.26, swift-sdk 0.12.1, argument-parser 1.8.2).

### Fixes

- International numbers keep an explicit `+` country code instead of being rewritten to `+1`.
- Short numeric destinations that are not valid phone numbers fall through to contact-name lookup.
- `search` and `find_chat contains_recent` scan the rows they claim to search, including attributedBody-only text.
- `AsyncTimeout.sleep` resumes when cancellation precedes arming; the regression test now fails in 2s instead of hanging.
- Duplicate `chat_handle_join` handles no longer trap participant dictionaries; display names are deduped before disambiguation.
- Session cap holds under concurrency; `server.stop()` runs on terminate; staged attachments are removed on every exit.
- `unanswered_hours`, search/find_chat/get_messages limits, and AppleTime overflow are clamped instead of trapping.
- LIKE wildcards are escaped (including the constant link filter); diagnose no longer leaks the home directory.
- Contact search matches on word boundaries and rejects empty queries.
- Relative dates use a pinned locale and the current time zone.

### Performance

- find_chat, search `include_context`, get_unread, list_chats totals, and send-by-name last-contact lookups are batched.
- Tool JSON is encoded in one pass; image dimensions are checked before a full decode; osascript pipes drain after timeout.
- HTTP transport starts before Contacts enumeration.

### Internals and DX

- One `Log` helper for stderr; `make verify` distinguishes a down server from bad JSON; launchd plist is shipped.
- Shared `ChatIdentifier`, `ChatSummaryQueries`, `ToolErrorMapping`, `TimelineCursor`, and `UnansweredHeuristics`.
- `QueryBuilder.where` accepts an array of bindings.
- `--version` prints `iMessage Max <version>`; `scripts/check-version.sh` and `make release-check` keep the four version sites aligned.
- CI and release workflows target `macos-26`, current action majors, and an arm64-only release asset.
