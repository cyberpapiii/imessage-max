# Release Checklist

Use this checklist before shipping a new build, publishing a release, or updating the Homebrew package.

This is intentionally lightweight. It is meant to catch the practical things that are easiest to miss in a local macOS MCP project: permissions, stale services, broken send flows, attachment handling, and live protocol behavior.

## 1. Local Build And Test

From `swift/`:

```bash
swift test
swift build -c release
make install
make status
```

Expected:
- tests pass cleanly
- release build succeeds
- `make install` restarts the service successfully
- `make status` shows the expected version, signature, and healthy server

## 2. Live MCP Sanity Check

Confirm a fresh HTTP session works against the running service:

1. Call `initialize`
2. Capture the returned `Mcp-Session-Id`
3. Call `tools/list` with that session id

Expected:
- initialize succeeds
- the session id is present
- `tools/list` returns 12 tools

Recommended quick check:

```bash
curl -X POST http://127.0.0.1:8080 \
  -H "Content-Type: application/json" \
  -H "Accept: application/json" \
  -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"release-check","version":"1.0"}}}'
```

Then reuse the returned session id for:

```bash
curl -X POST http://127.0.0.1:8080 \
  -H "Content-Type: application/json" \
  -H "Accept: application/json, text/event-stream" \
  -H "Mcp-Session-Id: <session-id>" \
  -d '{"jsonrpc":"2.0","id":2,"method":"tools/list","params":{}}'
```

## 3. Permission Check

Before shipping or testing on a fresh machine, confirm:

- Full Disk Access is granted to the signed binary
- Contacts access is granted
- Automation access for `Messages.app` is granted if `send` is expected to work

If the binary path changed, re-check Full Disk Access against the real binary path, not just a symlink.

## 4. Read-Path Spot Checks

Run a few quick real-world checks against your own data:

- `diagnose`
- `list_chats(limit=5)`
- `get_unread()`
- `search(query="test", limit=5)`
- `get_messages(chat_id="...", limit=5)`

Expected:
- tools return sensible JSON
- names resolve normally
- message retrieval still groups sessions and returns cursors
- no empty or obviously malformed responses from known-good chats

## 5. Attachment Spot Checks

Pick one known local image attachment and one known offloaded attachment if available.

Check:
- `list_attachments(type="image", since="30d")`
- `get_attachment(attachment_id="...", variant="thumb")`
- `get_attachment(attachment_id="...", variant="vision")`
- `get_attachment(attachment_id="...", variant="full")`

Expected:
- local attachments succeed across variants
- the offloaded attachment path returns a clear error instead of a broken response
- metadata and image sizing still look reasonable

## 6. Send Flow Spot Checks

Use the detailed checklist in:

- `docs/validation/2026-03-13-send-manual-validation.md`
- `swift/Tests/iMessageMaxTests/SendManualValidation.md`

Minimum release-level send checks:
- text send to a known 1:1 contact
- text send to a known group chat by exact `chat_id`
- attachment send to a known chat
- attachment + text ordering
- missing-file failure
- unsupported `reply_to` failure

Only do a deeper send polish pass if these checks show real friction.

## 7. Docs And Tool Count Check

Before shipping, confirm the public docs still match the running server:

- tool count is 11 everywhere
- no references to the retired Python implementation as if it were active
- usage examples still match current argument names and behavior

Quick search:

```bash
rg -n "12 tools|Update.swift|python implementation|cursor" README.md swift/README.md AGENTS.md docs
```

## 8. Final Release Questions

Before calling it done, answer:

- Does the installed service match the build I just made?
- Do the read tools still feel trustworthy on real data?
- Does send still work on a real thread, not just in tests?
- Do the docs describe the product that is actually running today?

If any answer is "not sure," do one more spot check before shipping.
