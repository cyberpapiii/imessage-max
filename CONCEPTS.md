# Concepts

This file defines the terms that mean something specific in this project: entities, named processes and statuses. It started with the core terms. The ce-compound and ce-compound-refresh processes add new terms as they find them, and direct edits are fine. It is a glossary. Do not use it as a spec or as a place for loose notes.

## Sending

- **Agent-native send contract**: The rules the send tool follows. It sends to an exact destination immediately, refuses an ambiguous one, and verifies the result after the send. There is no server-side confirmation gate and no interactive step. The tool refuses on ambiguity, which the server can detect. It does not refuse on risk, because judging risk belongs to the user's conversation with the agent and to the client's tool-approval step.

- **Verified send**: After a send, the server re-reads the Messages database to prove what happened to the message. It does not assume that an accepted send succeeded.

- **Unsent message**: A message its sender took back with Undo Send. chat.db keeps the row, clears its text and lists the unsent parts under `rp` in `message_summary_info`. The tools show it as `unsent: true` with no text, never as an edit.
- **Exact destination**: A send target with exactly one handle or chat: a known chat id, a phone number or email, or a contact name that matches exactly one number or email in Contacts. The handle need not be in chat.db; a send to a new handle starts the conversation. A name reaches a handle Messages has never seen only when it is the contact's full name, so "Sam" never starts a first conversation with a Samira. The server treats anything else as ambiguous and refuses it instead of guessing, including a name that matches two handles of one contact. A number saved without a country code is read in the Mac's region, and one that cannot be read that way never becomes a handle.

- **Region**: The Mac's region (`Locale.current.region`). A number written without a country code is read the way someone dialling in that region would: +1 only in a North American Numbering Plan region, and elsewhere the trunk prefix (such as the UK's 0) is dropped and the region's calling code added. A number that cannot be read without guessing is left unread.

## Send statuses

- **confirmed**: The server found the outbound row in chat.db within the verification window, with no error. This is the strongest success state, and it carries the verified message id as evidence. It is not a delivery receipt.

- **uncertain**: Verification could not find the message within the polling window. Either the transport accepted the send, or Messages failed or timed out after the send began (then disposition is `may_have_completed` and the result carries the error). The message may have been sent. Follow up by reading the conversation instead of retrying.

- **mismatch**: Verification found the message in a different conversation than the intended one. Never treat it as success.
- **failed_delivery**: Verification found the sent message with a delivery error recorded, so the message was not delivered. This is a failure, and the result carries the message id and error code as evidence.
- **partial_failure**: A send with several payloads dispatched some of them before a later one failed. The message lists which payloads were dispatched and which failed. Never retry the whole call blind. Retry only the failed payload.

- **sent**: The transport accepted the send, but verification was unavailable, so delivery is unproven.

- **pending_confirmation**: Messages accepted a file attachment send, but the file transfer had not finished within the polling window. This is a normal waiting state for attachments only. It is not a failure and not a request to retry. When text went with the file, `text_status` gives the text's own result (`confirmed` or `uncertain`).

- **Direct chat (DM)**: A 1:1 chat, `chat.style` 45, of any service (iMessage, SMS, RCS). A send with `to:` goes through the person's DM with the newest message. A group that everyone else left also has one participant but is not a DM.

- **ambiguous**: The server could not resolve the destination to exactly one conversation, so it sent nothing. Either several numbers or emails match, or the name is only part of the one matching contact's name and Messages has no conversation with that contact yet.

- **failed**: The input was invalid, or the send could not be dispatched. Nothing was verified, because nothing reliable was sent.

- **disposition**: How far the transport got: `completed` (Messages returned from `send`), `not_started` (failure before the Apple event), or `may_have_completed` (failure after the Apple event, or the server cannot tell). It is independent of `status`.

- **retry_safe**: `true` only when a retry cannot duplicate a message, because nothing reached Messages or chat.db recorded a delivery failure. `false` means do not resend blind.

## Diagnostics

- **Capability contract**: The fixed set of capability keys that the diagnose tool reports. Each key gives a state for what the install can do right now (supported, permission-gated, degraded, unverified, unsupported, unavailable), instead of a single healthy or unhealthy verdict. When the server cannot probe a capability, the key reports "unverified" instead of guessing. Automation is the one probe that needs Messages running: while Messages is closed, diagnose reports the last definite answer macOS gave (the remembered Automation answer). With none, or with one other than authorized, it starts Messages hidden to ask again, at most once every 5 minutes. Automation `not_determined` is `permission-gated` like `denied`, because a send never asks: on a headless Mac nobody could click the prompt. A Messages that is running but does not answer within 2 s reports `unverified` with detail `messages_not_responding`. `imessage_account` reads, with Automation granted, whether Messages has an iMessage account that is turned on and connected (detail `signed_in`); `signed_out`, `disabled` and `no_account` are `degraded` and also turn the send capabilities `degraded`, while `sms_only` (no iMessage account but a connected SMS account) and `connecting` leave sends as they are. The top-level `status` is `needs_setup` only when chat.db cannot be read; Contacts and Automation show in their own keys. The keys and state words live in `contract/Sources/IMessageMaxContract/`, which the server and the companion app share.

- **Setup step**: One of the four permissions the companion's home page lists, in order: Background activity, Full Disk Access, Contacts, Automation. Each title is the name System Settings uses. A diagnose `fix` for the helper inside the app names the permission to turn on ("Open iMessage Max and turn on Full Disk Access."), never a terminal command. The titles live in `contract/Sources/IMessageMaxContract/SetupStep.swift`. Connecting an assistant is not a setup step.
