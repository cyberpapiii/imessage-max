# Changelog

## 1.7.0

Seven techniques borrowed from a study of [openclaw/imsg](https://github.com/openclaw/imsg) (plans 079 to 085).

### Added

- `get_messages_since`: ROWID-cursor pull of new messages across chats, in arrival order. Call it with no cursor to get the current cursor, then poll with `since_rowid`.
- HTTP mode watches `chat.db` (kqueue on the db, wal, and shm files with inode re-arm, plus a fallback poll) and pushes `notifications/imessage/new_messages` over the legacy SSE stream when MAX(ROWID) grows. `diagnose` reports `live_inbox` as `supported` while the watcher runs.
- `send` responses carry `disposition` (`completed`, `not_started`, or `may_have_completed`) and `retry_safe`, derived from the phase the AppleScript reached. `confirmed` is documented as a chat.db row match within the verification window, not a delivery receipt.
- `diagnose` reports `database.features` from a schema probe of `chat.db`; the reply, edit, and custom-emoji columns are guarded by those flags instead of assumed.
- Headless Contacts access policy: the server asks for Contacts access only when started from a terminal. `--request-contacts-access` grants it once; `--contacts-policy request|skip` and `IMESSAGE_MAX_CONTACTS_POLICY` override the terminal detection. `diagnose` reports `not_requested_headless` with the exact command to run.
- `make verify-db` calls `diagnose` over HTTP after install and fails with Full Disk Access remediation when the database is not readable; `make install` is gated on it. The startup log and the `database.fix` string name the binary to add to Full Disk Access.

### Fixes

- `get_messages has:"links"` and `search has:"link"` match URL preview balloon rows; link-preview payload attachments are no longer listed.
- Send attachments are staged through a symlink-safe file handle into a 0700 directory; `SecurePath` normalizes the path lexically and rejects symlinks on every component.
- Contacts cache refreshes on a Contacts change and on a 30 s TTL, and is dropped as soon as access is revoked; no restart needed.
- A `permission_denied` database probe retries on the next query, so granting Full Disk Access takes effect without a restart.
- `perm_contacts` stays `supported` when the CI guard skips contact loading.

## 1.6.0

### Added

- `get_messages` renders group system messages (renames, member adds and removes) as a typed `event` object instead of null-text rows; previews describe them too.
- Messages carry `reply_to`, `reply_count`, and `edited`, mirrored onto `search` and `get_context` results.
- Custom emoji and sticker reactions are surfaced, and reaction removals are applied.
- `list_chats`, `search`, `get_unread`, and `find_chat` hide Apple-flagged filtered chats by default, report the hidden count as `filtered_hidden`, and accept `include_filtered`.
- `get_context contains` searches past the newest 500 messages and reports `not_found_in_window` at the cap.

### Removed

- The `reply_to` parameter on `send`. It was never implemented; the Messages scripting interface has no reply primitive.

### Fixes

- Paginated tools derive `more` from the cursor, so `more:true` with a null cursor no longer appears on a no-message tail.
- `ChatIdentifier` rejects sign-prefixed row ids; `get_unread chat_not_found` is valid JSON; `queryFailed` and `invalidData` map to the fixed internal-error text.
- `Database.prepare` checks every `sqlite3_bind_*` return code.
- `terminateSession` removes the session before stopping its server; `ResumeGate.arm` no longer enqueues a timer for an already-resumed task.
- HTTP request body reads are bounded by a 408 deadline; the Hummingbird idle timeout is enabled on the HTTP1 channel.
- `diagnose` reports contacts as `skipped_ci` when the CI guard is active.

### Performance

- Recent senders and attachment types are prefetched once per page in `list_chats`, `find_chat`, `get_active_conversations`, and `get_unread`.
- Search bounds context windows per anchor, builds the link detector and preview regexes once, and produces one `ChatIdentity` per chat.

### Internals and DX

- `ChatIdentity` is the only chat display-name producer.
- `PendingRequestRegistry` and request parsing are extracted from `HTTPTransport`; `list_attachments` and `get_active_conversations` use `QueryBuilder`.
- Release workflow times out, checks the tag, asserts the version, and publishes the tarball sha256; actions are SHA-pinned with Dependabot; the Formula is part of the version check.
- Spike findings for a one-call catch-up sweep and send delivery semantics live under `docs/plans/`.

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
