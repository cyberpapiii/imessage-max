# Concepts

Shared domain vocabulary for this project: entities, named processes, and status concepts that mean something specific here. It started with the core terms and grows as the ce-compound and ce-compound-refresh processes turn up new ones. Direct edits are fine. This is a glossary, not a spec and not a place to park loose notes.

## Sending

- **Agent-native send contract**: The send tool's behavioral contract. An exact destination sends immediately, an ambiguous one is refused, and the result is verified after the send. There is no server-side confirmation gate and no interactive step. Refusal keys on ambiguity (which the server can detect), not riskiness (which is a judgment that belongs to the user's conversation with the agent and the client's tool-approval step).

- **Verified send**: Post-send verification where the server re-reads the Messages database to prove what actually happened to a sent message, instead of trusting that an accepted send succeeded.

- **Exact destination**: A send target that resolves to exactly one conversation: a known chat id, or a participant lookup with a single match. Anything else is ambiguous and refused rather than guessed.

## Send statuses

- **confirmed**: The sent message was found in the Messages database with no error; the strongest success state, carrying the verified message id as evidence.

- **uncertain**: Transport accepted the send but verification could not find the message within the polling window; follow up by reading the conversation rather than retrying.

- **mismatch**: Verification found the message in a different conversation than intended; never treated as success.
- **failed_delivery**: Verification found the sent message recorded with a delivery error; the message did not deliver. Treated as a failure, with the message id and error code as evidence.
- **partial_failure**: A send carrying several payloads dispatched some of them before a later one failed; the message lists which were dispatched and which failed. Never blind-retry the whole call. Retry only the failed payload.

- **sent**: Transport accepted the send but verification was unavailable, so delivery is unproven.

- **pending_confirmation**: A file attachment send was accepted but the file transfer had not finished within the polling window; a normal attachment-only waiting state, not a failure and not a request to retry.

- **ambiguous**: The destination could not be resolved to exactly one conversation, so nothing was sent.

## Diagnostics

- **Capability contract**: The fixed set of state-based capability keys the diagnose tool reports, each describing what the install can actually do right now (supported, permission-gated, degraded, unverified, unsupported, unavailable) rather than a binary healthy/unhealthy verdict. When a capability cannot be probed, for example when the target application is not running, it reports "unverified" instead of guessing.
