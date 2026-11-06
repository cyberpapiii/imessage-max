---
title: Agent-native send tools never gate synchronous tool calls on MCP elicitation
date: 2026-06-11
category: architecture-patterns
module: imessage-max send tool (Swift MCP server, streamable HTTP, launchd service)
problem_type: architecture_pattern
component: tooling
severity: critical
symptoms:
  - "No-confirm chat_id send through the plug MCP multiplexer hung 300 seconds until the client transport timeout"
  - "After a bounded-timeout fix built on Task.sleep, the same send crashed the launchd service instantly (freed pointer was not the last allocation, swift_task_dealloc abort, exit status 6)"
  - "Sends with confirm:true and to-route sends worked perfectly, masking the dead elicitation channel"
  - "The gated client, told to retry with confirm:true, did so immediately and unprompted. The safety boolean gated nothing"
applies_when:
  - "Designing MCP tools that consider server-initiated elicitation for confirmation flows"
  - "An MCP server runs behind a multiplexer or any client stack where SSE delivery and elicitation capability are unverified"
  - "Building agent-facing tools with side effects (send, delete, pay) that need a safety checkpoint"
  - "Using timers or sleeps in unstructured Swift tasks inside a launchd-managed service"
root_cause: missing_validation
resolution_type: code_fix
related_components:
  - swift/Sources/iMessageMax/Send/SendTool.swift
  - swift/Sources/iMessageMax/Server/HTTPTransport.swift
  - swift/Sources/iMessageMax/Server/SSEConnection.swift
  - swift/Sources/iMessageMax/Server/SessionManager.swift
  - swift/Sources/iMessageMax/Utilities/AsyncTimeout.swift
tags:
  - mcp-elicitation
  - agent-native-tools
  - send-confirmation
  - sse-broadcast
  - launchd
  - swift-concurrency
  - task-sleep-crash
  - plug-multiplexer
---

# Agent-native send tools never gate synchronous tool calls on MCP elicitation

## Context

The send tool gated every `chat_id` send behind MCP elicitation, a server-initiated
confirmation popup that the 2026-05-16 MCP modernization plan introduced. The popup's
round trip had never completed in the real client stack (agent harness, then plug
multiplexer, then imessage-max over streamable HTTP). So the most common agent flow,
`find_chat` followed by `send(chat_id, text)`, always failed. It failed in three ways,
each worse than the last:

1. 300s hang (original code). `server.requestElicitation` awaited with no timeout on a
   channel that never answered. The client's own 300s MCP transport timeout killed
   the call.
2. Instant production crash (plan 014). Bounding the wait with a `withTaskGroup` plus
   `Task.sleep` race crashed the launchd service on the first real send: `freed pointer
   was not the last allocation`, abort in `swift_task_dealloc`, `launchctl`
   `LastExitStatus = 6`. The gate failed closed and no message leaked, but the service
   died mid-request.
3. 25s stall (plan 015). With launchd-safe Dispatch timers, the path fell back to
   `pending_confirmation` without crashing. Every gated send still spent 25 seconds
   waiting for a popup that could not be delivered, then told the agent to retry with
   `confirm: true`. In a live run, the agent retried at once without being asked. The
   safety boolean gated nothing.

The root cause, verified in the code and confirmed by a second Codex investigation,
was that the design confused "I received a tool call" with "I can interrupt the user
and get an answer back." Nobody verified two preconditions for elicitation.

- The server never checked the client capability. The MCP Swift SDK's
  `requestElicitation` calls `validateClientCapability(\.elicitation)`, but that check
  does nothing unless `Server.Configuration.strict == true`, and the server creates
  per-session Servers with the default `strict: false`.
- The server could drop the request without an error. It broadcasts server-originated
  requests that match no pending HTTP request over SSE, and `SSEConnection.broadcast`
  begins with `guard let connectionIds = sessionConnections[sessionId] else { return }`.
  With zero SSE connections for the session, which is the normal state in the plug
  stack, the elicitation request is discarded while `requestElicitation` waits for a
  response that can never arrive.

## Guidance

A tool with side effects must behave like a synchronous command. The agent calls it,
gets a truthful result, and moves on. Agents cannot wait for popups, receive delayed
callbacks, or wake up later when a human answers. Authorization happens in the user's
conversation with the agent and in the harness's tool-approval UI, not server-side.

The agent-native send contract (plan 017, net 71 lines removed):

- An exact destination sends immediately, then verifies by re-reading chat.db. The
  result is `confirmed` (carrying `verified_message_guid` as evidence), `uncertain`
  (follow up with `get_messages`), `mismatch` (it landed in the wrong chat, so alert
  the user and never treat it as success), or `sent` (the database was unreadable, so
  only the transport accepted it).
- An ambiguous destination returns status `ambiguous` and sends nothing. Invalid input
  returns `failed` and sends nothing. The tool refuses on ambiguity, which the server
  can detect, not on risk, which is a judgment for the user's conversation.
- File transfers keep a bounded `pending_confirmation` observation state while
  Messages.app completes the transfer. That is state observation, not human
  confirmation, and it returns promptly.
- `confirm` stays in the schema but has no effect and is documented as deprecated, so
  existing callers and harness-cached tool schemas do not break.

A related rule covers the runtime. Never use `Task.sleep` anywhere in the launchd
service runtime. Sleeping unstructured Swift tasks abort in `swift_task_dealloc` at wakeup in
this runtime. Use Dispatch timers instead. `AsyncTimeout.sleep` resumes a
`CheckedContinuation` from a cancellable `DispatchSourceTimer`, and
`PendingRequestRegistry.store` uses the same kind of timer. Avoid `asyncAfter`,
because a cancelled `asyncAfter` work item stays queued, with everything it
captured, until its deadline.

## Why this matters

- An agent-set boolean is not a safety mechanism. Any agent learns to pass
  `confirm: true` within one session. The live client did it on the next call without
  being asked. A flag that the caller sets for itself filters nothing, and it costs an
  extra round trip and a longer tool description.
- The human checkpoint already exists in the client. MCP harnesses show the user each
  tool call and its arguments before it runs. Server-side confirmation duplicates that
  check, less well, behind a channel that the server cannot verify exists.
- A broken optional path still has a cost. Keeping elicitation as a guarded fallback
  was considered and rejected. Agents would still reach it sometimes, tests would have
  to pin it, docs would have to explain it, and every later debugging session would
  have to rule it out. Delete code that cannot work in the deployed stack. Do not make
  it optional.
- Honest verification after the send does more than a gate before it. Post-send
  chat.db verification caught a real silent failure. Messages accepted a send and then
  wrote an `error=22` row, and the old logic reported that as success because
  AppleScript had not returned an error.

## When to apply

- Any MCP server feature built on server-initiated requests, meaning elicitation or
  sampling. Verify that the client declared the capability, because the SDK check does
  nothing unless `strict: true`. Also verify that a live server-to-client channel
  exists at request time. A `guard ... else { return }` on a broadcast path means
  silent drops, not errors. Prove one full round trip in the real client stack before shipping any code
  path that blocks on the response.
- Any agent-facing mutation tool such as send, delete, or pay. Refuse an ambiguous
  target, act on an exact one, verify afterwards, and report the result honestly. Do
  not add agent-settable booleans as gates.
- Any timer or sleep inside the launchd service. Use only Dispatch timers. Search the
  repo's own comments before adding concurrency code. The plan 014 crash broke a
  constraint that a comment in `PendingRequestRegistry.store` already stated.
- Reintroducing any send gate requires operator sign-off and session-level proof of a
  working elicitation round trip, per the `AGENTS.md` send contract and the
  `Send/SendTool.swift` policy comment. A new gate must add safety that an agent-set
  boolean cannot defeat, and it must never block on an interactive channel.

## Examples

The gate that was removed (before, `SendTool.send`):

```swift
if shouldConfirmSend(resolved: resolved, text: text, filePaths: filePaths), !confirm {
    switch await confirmSendWithClientIfAvailable(server: server, resolved: resolved, ...) {
    case .confirmed: break
    case .declined:
        return .cancelled("Send cancelled by user confirmation.", ...)
    case .unavailable:
        return .pending("This send requires confirmation. Call send again with confirm: true ...", ...)
    }
}
```

After (the policy, recorded where the gate used to be):

```swift
// Sends are authorized by the user's request to the agent and by
// harness-level tool approval. The server does not gate exact sends.
// Ambiguity and validation failures refuse above, and post-send
// verification reports the truth below. Interactive confirmation (MCP
// elicitation) was removed 2026-06-11 after it proved unable to
// round-trip through real agent stacks. See "Elicitation channel
// findings" in plans/README.md. Do not reintroduce without
// session-level proof of a working channel.
```

The timeout attempt that crashed production (plan 014, do not reintroduce):

```swift
// CRASHED: Task.sleep in an unstructured task aborts in this launchd runtime
group.addTask {
    try? await Task.sleep(for: timeout)   // swift_task_dealloc abort at wakeup
    return nil
}
```

The first launchd-safe replacement (plan 015). The current `AsyncTimeout.sleep`
in `Utilities/AsyncTimeout.swift` replaced its `asyncAfter` with a cancellable
`DispatchSourceTimer`:

```swift
static func sleep(_ duration: Duration) async {
    await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
        DispatchQueue.global(qos: .utility).asyncAfter(
            deadline: .now() + dispatchInterval(for: duration)
        ) { cont.resume() }
    }
}
```

The guard in `SSEConnection.broadcast` that silently dropped the elicitation
requests. It is unchanged, so design around it:

```swift
func broadcast(sessionId: String, event: String) {
    guard let connectionIds = sessionConnections[sessionId] else { return }  // zero connections means a silent drop
    ...
}
```

In a live check after the fix, the previously failing call returned `confirmed` with a
verified guid in about one second. The service PID stayed the same, and the crash log
had nothing new.

## Related

- `plans/README.md`, section "Elicitation channel findings (2026-06-11 live
  debugging)", has the main root-cause writeup. Plan tracker rows 014 (timeout,
  crashed), 015 (Dispatch timers, commit `efe1c27`), 016 (rejected, superseded), 017
  (gate removed, commits `74855c4` and `834d10c`).
- `plans/017-agent-native-send-contract.md` is the executed plan, including the
  recorded reasoning so the gate is not re-litigated.
- `plans/015-launchd-safe-timers.md` and
  `plans/014-bounded-confirmation-elicitation.md` cover the mechanical crash fix and
  the superseded timeout attempt.
- `docs/plans/2026-06-11-send-verification-design.md` designs the post-send chat.db
  verification that replaced the gate as the trust mechanism.
- `docs/plans/2026-06-11-capability-contract-design.md` covers the capability-contract
  design, relevant to the "client capability never checked" thread.
- `docs/plans/2026-05-16-mcp-2025-11-25-modernization-plan.md` is the superseded
  origin. Its "Key Decision 4" and Unit 5 prescribed the elicitation-gated send this
  learning removes.
- `AGENTS.md` has the prevention rules as written policy: "Send contract (no
  confirmation gate)" and "No Task.sleep in the service runtime".
- (auto memory [claude]) The operator routes all MCP servers through the plug
  multiplexer globally on this machine. That is the client chain that elicitation had
  to pass through.
