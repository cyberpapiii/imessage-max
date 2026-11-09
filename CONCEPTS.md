# Concepts

This file defines the terms that mean something specific in this project: entities, named processes and statuses. It started with the core terms. The ce-compound and ce-compound-refresh processes add new terms as they find them, and direct edits are fine. It is a glossary. Do not use it as a spec or as a place for loose notes.

## Sending

- **Agent-native send contract**: The rules the send tool follows. It sends to an exact destination immediately, refuses an ambiguous one, and verifies the result after the send. There is no server-side confirmation gate and no interactive step. The tool refuses on ambiguity, which the server can detect. It does not refuse on risk, because judging risk belongs to the user's conversation with the agent and to the client's tool-approval step.

- **Verified send**: After a send, the server re-reads the Messages database to prove what happened to the message. It does not assume that an accepted send succeeded.

- **Exact destination**: A send target that resolves to exactly one conversation: a known chat id, or a participant lookup with a single match whose handle is already in chat.db. The server treats anything else as ambiguous and refuses it instead of guessing. A contact name that matches only a Contacts number or email Messages has never seen is ambiguous, because a number misread from Contacts could reach a stranger.

- **Region**: The Mac's region (`Locale.current.region`). A number written without a country code is read the way someone dialling in that region would: +1 only in a North American Numbering Plan region, and elsewhere the trunk prefix (such as the UK's 0) is dropped and the region's calling code added. A number that cannot be read without guessing is left unread.

## Send statuses

- **confirmed**: The server found the outbound row in chat.db within the verification window, with no error. This is the strongest success state, and it carries the verified message id as evidence. It is not a delivery receipt.

- **uncertain**: The transport accepted the send, but verification could not find the message within the polling window. Follow up by reading the conversation instead of retrying.

- **mismatch**: Verification found the message in a different conversation than the intended one. Never treat it as success.
- **failed_delivery**: Verification found the sent message with a delivery error recorded, so the message was not delivered. This is a failure, and the result carries the message id and error code as evidence.
- **partial_failure**: A send with several payloads dispatched some of them before a later one failed. The message lists which payloads were dispatched and which failed. Never retry the whole call blind. Retry only the failed payload.

- **sent**: The transport accepted the send, but verification was unavailable, so delivery is unproven.

- **pending_confirmation**: Messages accepted a file attachment send, but the file transfer had not finished within the polling window. This is a normal waiting state for attachments only. It is not a failure and not a request to retry.

- **ambiguous**: The server could not resolve the destination to exactly one conversation, so it sent nothing. Either several contacts match, or the one match is a Contacts number or email with no conversation in Messages.

- **failed**: The input was invalid, or the send could not be dispatched. Nothing was verified, because nothing reliable was sent.

- **disposition**: How far the transport got: `completed` (Messages returned from `send`), `not_started` (failure before the Apple event), or `may_have_completed` (failure after the Apple event, or the server cannot tell). It is independent of `status`.

- **retry_safe**: `true` only when a retry cannot duplicate a message, because nothing reached Messages or chat.db recorded a delivery failure. `false` means do not resend blind.

## Diagnostics

- **Capability contract**: The fixed set of capability keys that the diagnose tool reports. Each key gives a state for what the install can do right now (supported, permission-gated, degraded, unverified, unsupported, unavailable), instead of a single healthy or unhealthy verdict. When the server cannot probe a capability, the key reports "unverified" instead of guessing. Automation is the one probe that needs Messages running: while Messages is closed, diagnose reports the last definite answer macOS gave (the remembered Automation answer), and with none it starts Messages hidden once to get one. The keys and state words live in `contract/Sources/IMessageMaxContract/`, which the server and the companion app share.

- **Setup step**: One of the four permissions the companion's home page lists, in order: Background activity, Full Disk Access, Contacts, Automation. Each title is the name System Settings uses. A diagnose `fix` for the helper inside the app names the permission to turn on ("Open iMessage Max and turn on Full Disk Access."), never a terminal command. The titles live in `contract/Sources/IMessageMaxContract/SetupStep.swift`. Connecting an assistant is not a setup step.
