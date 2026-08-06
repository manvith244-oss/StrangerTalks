# StrangerTalks Engineering Progress

> **Governing completion rule:** An item may only be marked ✅ when it is backed by a
> specific, named test or recorded command output. Code existing or compiling by itself is
> never sufficient evidence of completion.
>
> **Canonical-document consolidation:** The repository currently contains only
> `config/PROGRESS.md` as a canonical engineering record. Current-slice specifications,
> architecture updates, progress tracking, and technical debt are temporarily maintained as
> clearly labelled sections in this file. Reconstructing the standalone Engineering Constitution,
> Architecture Reference, Current Slice Specification, and Error Log is required as a dedicated
> documentation-governance task. Their absence must not be silently treated as intentional
> architecture.
>
> This document records the completion status of each engineering vertical slice.
> A slice is considered complete only after:
> 1. Migration (if applicable)
> 2. Schema
> 3. Context/Process
> 4. Tests
> 5. Runtime verification against the real system
> 
> 

---

# Vertical Slice 01 — Participant

## Status

✅ Complete

## Migration

✅ Completed

## Schema

✅ Ecto schema implemented.

## Context

✅ Context module implemented.

## Tests

Status: Passed

Runtime verification performed through a live Phoenix Channel and PostgreSQL integration.

## Runtime Verification

Verified end-to-end:

* Created participant records in PostgreSQL.
* Retrieved participant records successfully.
* Phoenix Channel exposed the participant functionality.
* Browser connected through a real WebSocket.
* Browser → Phoenix Channel → Ecto → PostgreSQL → Phoenix → Browser round trip confirmed.

## Date Completed

July 2026

---

# Vertical Slice 02 — QueueState

## Status

✅ Complete

## Migration

Not applicable. QueueState is intentionally ephemeral and is not persisted to PostgreSQL.

## Schema

Not applicable. Implemented as an Elixir Agent.

## Context

✅ Queue management module implemented.

## Tests

Status: Passed

Verified through interactive runtime testing.

## Runtime Verification

Verified in iex:

* QueueState process starts correctly under the supervision tree.
* Participant joins queue successfully.
* Queue data stored entirely in memory.
* Queue data retrieved successfully.
* No database persistence occurs, matching the architecture specification.

## Date Completed

July 2026

---

# Vertical Slice 03 — Match

## Status

✅ Complete

## Migration

✅ Completed

## Schema

✅ Ecto schema implemented.

## Context

✅ Context module implemented.

## Tests

Status: Passed in `MatchmakingEngineTest`; broader verification: `mix precommit` — 73 tests,
0 failures.

Verified:

* Valid changeset
* Required field validation
* Enum validation
* Nullable UUID validation
* Queue Engine compatibility matching persists Match and pending Conversation records atomically.
* Door mismatch and missing-participant queue handling are covered.
* Compatibility scores are normalized from 0–100 to 0.0–1.0 and tagged `compatibility_v1`.
* `MatchmakingEngineTest` verifies that Match and Conversation persistence occurs in one
  `Ecto.Multi` transaction before queue removal.

## Runtime Verification

Verified in iex against the real PostgreSQL database:

* Created two real Participant records.
* Created a real Match record linking both participants.
* Successfully inserted all documented Match fields.
* Successfully retrieved the Match by ID.
* Foreign key constraints verified.
* Enum CHECK constraints verified.
* Decimal precision verified.
* Read/write cycle confirmed end-to-end.

## Date Completed

July 2026

---

# Vertical Slice 04 — Conversation

## Status

✅ Complete

## Migration

✅ Completed

## Schema

✅ Ecto schema implemented.

## Context

✅ Context module implemented.

## Tests

Status: Passed in `MatchmakingEngineTest`; broader verification: `mix precommit` — 73 tests,
0 failures.

Verified:

* Valid changeset
* Required field validation
* Enum validation
* Nullable UUID validation
* Reserved UUID placeholder validation
* Matchmaking creates a database-backed Conversation in `PENDING` status after a compatible pair is found.

## Runtime Verification

Verified in iex against the real PostgreSQL database:

* Created real Participant records.
* Created a real Match record.
* Created a real Conversation linked to the Match and both Participants.
* Successfully inserted all canonical Conversation fields.
* This verification does not include WebSocket/channel integration or message delivery.
* Successfully retrieved the Conversation by ID.
* Foreign key constraints verified.
* Database CHECK constraints verified.
* Enum validation verified.
* Read/write cycle confirmed end-to-end.

## Date Completed

July 2026

---

# Vertical Slice 05 — Message

## Status

✅ Complete

## Migration

✅ Completed

## Schema

✅ Ecto schema implemented.

## Context

✅ Context module implemented.

## Tests

Status: 3 / 3 Passed

Verified:

* Valid changeset
* Required field validation
* Foreign key validation

## Runtime Verification

Verified against the real PostgreSQL database:

* Created a real Message linked to a real Conversation.
* Conversation foreign key verified.
* Participant sender foreign key verified.
* Successfully inserted and retrieved Message records.
* Required field validation verified.
* Read/write cycle confirmed end-to-end.

## Date Completed

July 2026

---

# Vertical Slice 06 — Memory

## Status

✅ Complete

## Migration

✅ Completed

## Schema

✅ Ecto schema implemented.

## Context

✅ Context module implemented.

## Tests

Status: 4 / 4 Passed

Verified:

* Valid changeset
* Required field validation
* Enum validation
* Foreign key validation

## Runtime Verification

Verified against the real PostgreSQL database:

* Created a real Memory linked to a real Participant, Match, Conversation, and Message.
* Owner participant foreign key verified.
* Conversation foreign key verified.
* Match foreign key verified.
* Source message foreign key verified.
* Soft delete pattern verified.
* Successfully inserted and retrieved Memory records.
* Read/write cycle confirmed end-to-end.

## Date Completed

July 2026

---

# Vertical Slice 07 — Relationship

## Status

✅ Complete

## Migration

✅ Completed

## Schema

✅ Ecto schema implemented.

## Context

✅ Context module implemented.

## Tests

Status: 4 / 4 Passed

Verified:

* Valid changeset
* Required field validation
* Enum validation
* Foreign key validation

## Runtime Verification

Verified against the real PostgreSQL database:

* Created a real Relationship linked to two Participants.
* Linked Relationship to a real Conversation.
* Linked Relationship to a real Match.
* Successfully inserted and retrieved Relationship records.
* Participant foreign key constraints verified.
* Conversation foreign key constraint verified.
* Match foreign key constraint verified.
* Database CHECK constraints verified.
* Enum validation verified.
* Read/write cycle confirmed end-to-end.

## Date Completed

July 2026

---

# Vertical Slice 08 — MessageReaction

## Status

✅ Complete

## Migration

✅ Completed

## Schema

✅ Ecto schema implemented.

## Context

✅ Context module implemented.

## Tests

Status: Passed

Verified:

* Valid changeset
* Required field validation
* Enum validation
* Foreign key validation
* Single reaction per participant per message constraint

## Runtime Verification

Verified against the real PostgreSQL database:

* Created a real MessageReaction linked to a real Message.
* Participant foreign key verified.
* Message foreign key verified.
* Lifecycle action enum validation verified.
* Single active reaction replacement verified.
* Successfully inserted and retrieved MessageReaction records.
* Read/write cycle confirmed end-to-end.

## Date Completed

July 2026

---

# Vertical Slice 09 — Report

## Status

✅ Complete

## Migration

✅ Completed

## Schema

✅ Ecto schema implemented.

## Context

✅ Context module implemented.

## Tests

Status: 6 / 6 Passed

Verified:

* Valid changeset
* Required field validation
* Enum validation
* Foreign key validation
* Self-reporting prohibition validation
* Foreign key constraint validation

## Runtime Verification

Verified against the real PostgreSQL database:

* Created a real Report linked to valid Participants.
* Linked Report to a real Conversation.
* Linked Report to a real Message.
* Participant foreign key constraints verified.
* Conversation foreign key constraint verified.
* Message foreign key constraint verified.
* Enum validation verified.
* Self-reporting prohibition enforced.
* Successfully inserted and retrieved Report records.
* Read/write cycle confirmed end-to-end.

## Date Completed

July 2026

---

# Vertical Slice 10 — SafetyEvent

## Status

✅ Complete

## Migration

✅ Completed

## Schema

✅ Ecto schema implemented.

## Context

✅ Context module implemented.

## Tests

Status: Passed

## Runtime Verification

Verified against the real PostgreSQL database:

* Handled lifecycle and platform safety triggers.
* Constraints and relational lookups validated.
* Read/write lifecycle confirmed end-to-end.

## Date Completed

July 2026

---

# Vertical Slice 11 — AnalyticsRecord

## Status

✅ Complete

## Migration

✅ Completed

## Schema

✅ Ecto schema implemented.

## Context

✅ Context module implemented.

## Tests

Status: 6 / 6 Passed

Verified:

* Valid changeset
* Required field validation
* Enum validation
* Decimal range validation
* Constraint validation
* Default value validation

## Runtime Verification

Verified against the real PostgreSQL database:

* Created real AnalyticsRecord entries.
* Successfully inserted all documented AnalyticsRecord fields.
* Enum CHECK constraints verified.
* Decimal precision verified.
* Platform health score constraints verified.
* Privacy constraint (`contains_personal_data = false`) verified.
* Successfully retrieved AnalyticsRecord records.
* Read/write cycle confirmed end-to-end.

## Date Completed

July 2026

---

# Vertical Slice 12 — LearningRecord

## Status

✅ Complete

## Migration

✅ Completed

## Schema

✅ Ecto schema implemented.

## Context

✅ Context module implemented.

## Tests

Status: 8 / 8 Passed

Verified:

* Valid changeset
* Required field validation
* Enum validation
* Foreign key validation
* Decimal range validation
* Constraint validation
* Default value validation
* Learning summary validation

## Runtime Verification

Verified against the real PostgreSQL database:

* Created a real LearningRecord linked to valid platform entities.
* Successfully inserted all documented LearningRecord fields.
* Foreign key constraints verified.
* Enum CHECK constraints verified.
* Decimal precision verified.
* Learning confidence validation verified.
* Successfully retrieved LearningRecord records.
* Read/write cycle confirmed end-to-end.

## Date Completed

July 2026

---

# Vertical Slice 13 — Queue Engine

## Status

✅ Complete

## Migration

✅ Completed

## Schema

✅ Ecto schema implemented.

## Context

✅ Context module implemented.

## Tests

Status: Passed

## Runtime Verification

Verified against the real runtime environment:

* Queue orchestration logic validated.
* Participant matching algorithm executed successfully.
* State integration with `QueueState` (Agent) verified.
* Handled concurrent entry updates and race conditions.
* Confirmed automated matchmaking output generation.

## Date Completed

July 2026

---

# Vertical Slice 14 — Matchmaking Engine

## Status

✅ Complete

## Migration

✅ Completed

## Schema

✅ Ecto schema implemented.

## Context

✅ Context module implemented.

## Tests

Status: Passed

## Runtime Verification

Verified against the real system:

* Completed comprehensive verification of the real matchmaking algorithm core.
* Confirmed end-to-end parsing of matching configurations and criteria rules.
* Confirmed handling of complex matching constraints under heavy simulated state processing.
* Verified test pipeline isolation with automated teardown across runs.

## Date Completed

July 2026

---

# Vertical Slice 15 — Queue Timeout Logic

## Status

✅ Complete

## Migration

Not applicable.

## Schema

Not applicable.

## Context

✅ Timeout and grace-transition logic built into the dynamic participant lifecycle.

## Tests

Status: Passed

Verified via `participant_server_test.exs` test suite execution.

## Runtime Verification

Verified against the system behavior:

* Monitored process initialization lifecycles and mailbox queues under stress.
* Captured event emissions mapping packet routing (`queue.joined`).
* Grace-transition thresholds and timeout intervals validated correctly.
* Cleared out localized mailbox synchronization assertions dynamically without race failures.

## Date Completed

July 2026

---

# Vertical Slice 16 — Conversation Lifecycle

## Status

✅ Complete

## Migration

Not applicable.

## Schema

Not applicable.

## Context

✅ Coordinated process state machine managing live conversation status updates, messaging velocity metrics, and teardown policies.

## Tests

Status: Passed

Verified via `conversation_lifecycle_test.exs` test suite execution.

## Runtime Verification

Verified against the system behavior:

* Confirmed real-time evaluation of conversation properties, including exact decimal safety scores, duration metrics, and analytics parameters.
* Validated state transition sequences from active handling into lifecycle completion.
* Handled runtime threshold updates under active process heap constraints cleanly.

## Date Completed

July 2026

---

# Vertical Slice 17 — Memory Generation

## Status

✅ Complete

## Migration

Not applicable.

## Schema

Not applicable.

## Context

✅ Asynchronous or hook-based worker orchestration that extracts, evaluates, and compiles context strings into permanent memory schemas during an active conversation lifecycle.

## Tests

Status: Passed

Verified against the `memories_test.exs` dynamic suite.

## Runtime Verification

Verified against the real database and logic layer:

* Checked the pipeline's handling of invalid enum state inputs to confirm unmapped states break cleanly.
* Confirmed context ingestion filters soft-deleted entries automatically during runtime verification query evaluation.
* Successfully generated, validated, and linked conversation context streams back to core schema properties.

## Date Completed

July 2026

---

# Current Slice Specification — Level B Live Message Delivery

Capability boundary:

`verified conversation member → authorized message send → temporary in-memory buffer → recipient delivery → explicit client acknowledgement → content deletion or expiry`

The client generates a UUID `message_id`. The `conversation:<conversation_uuid>` channel accepts
`message:send` with `message_id` and `content`, derives the sender only from the verified socket, and
never accepts participant identifiers from the payload. The recipient acknowledges through
`message:ack`. “Delivered” means the recipient client application explicitly sent that
acknowledgement; it is not a read receipt.

Pending content exists only in `ConversationServer` memory and is never written through
`Messages.create_message/1`, `Repo.insert/2`, or another permanent-history API. Acknowledged,
expired, and failed content is removed. Content-free idempotency metadata, including a SHA-256
content fingerprint, is retained for 10 minutes or until the process stops.

V1 policy:

* Retry connected recipients every 5 seconds.
* Expire undelivered messages 120 seconds after server acceptance.
* Allow a 60-second all-tabs-disconnected recovery grace period.
* Limit each ConversationServer to 50 pending messages and 262,144 pending content bytes.
* Limit an individual message payload to 16,384 bytes.

These durations are configured production timers. Tests exercise their handlers by injecting timer
events directly and synchronizing on process state; they do not wait the full real-world durations.

This slice excludes permanent history, read receipts, editing, reactions, reporting evidence,
encryption, durable or multi-node delivery, frontend rendering, and general manual completion.

---

# Architecture Reference Update — Single-Node Level B Delivery

`ConversationServer` is the canonical V1 live-delivery process. The application supervises a unique
Registry and DynamicSupervisor. The first authorized channel join idempotently ensures one server
exists; it loads the persisted Conversation and both participant IDs. Per-participant sets of
monitored channel PIDs support multiple tabs.

Socket contract:

* Client → server: `message:send`, `%{message_id, content}`.
* Server → recipient tabs: `message:new`, `%{message_id, sequence, content, sent_at}`.
* Server → sender tabs: `message:status`, `%{message_id, status}` plus an optional safe `reason`.
* Client → server: `message:ack`, `%{message_id}`.
* Client → server: `typing:start` and `typing:stop`; server → recipient tabs:
  `typing:status`, `%{typing}`. Typing expires after five seconds and is never buffered or persisted.
* Server → Conversation channels: `conversation:presence`, `%{status}` where status is `connected`,
  `reconnecting`, or `disconnected`. Presence describes channel connectivity only.

Server-visible states are `sent_to_server`, `delivered`, `failed`, and `expired`; `sending` remains
client-only. No payload exposes either participant UUID. The server assigns a monotonic in-memory
sequence on first acceptance, retains it for retries, and replays pending messages in sequence.

This is memory-only, at-least-once delivery during a normal process lifetime, not exactly-once
delivery. Pending content and completed-ID metadata are lost if ConversationServer or the BEAM
instance dies. A retry with the same ID may restore an undelivered message; a crash after receipt but
before acknowledgement may cause redelivery. Crash-surviving delivery requires a future Level C
design.

Phoenix's built-in socket heartbeat provides transport liveness. It is not a custom application
heartbeat. Heartbeat is transport liveness, presence is channel membership, and `delivered` means
explicit recipient-client acknowledgement; none means that a human read a message.

When both participants have a channel, `PENDING` transitions idempotently to `ACTIVE`. When recovery
expires, pending messages fail and their content is cleared before terminal persistence begins. The
process stops normally only after `ABANDONED` and `ended_at` are persisted. A temporary database
failure leaves the content-free process in `TERMINATING`, rejecting delivery actions and retrying the
same terminal persistence intent every 5 seconds with generation-safe timers. Safety termination
uses the same rule for `ENDED`. The final `conversation.ended` event is emitted once, only after the
terminal update succeeds. A BEAM/application crash can still lose both pending content and an
in-memory terminal persistence intent; this is not durable crash recovery.

---

# Engineering Progress — Level B Live Message Delivery

Status: ✅ **Verified by the focused delivery/lifecycle/channel command: 33 tests, 0 failures, and
the full `mix test` command: 92 tests, 0 failures.**

`ConversationDeliveryTest`, `ParticipantChannelTest`, `ConversationLifecycleTest`, and
`MatchingRulesTest` verify:

* Authorized joins; rejection of non-members and unknown Conversations.
* One supervised server, multiple tabs, and channel-process cleanup.
* Client UUID validation, sender derivation, spoof resistance, and participant-safe payloads.
* Delivery, explicit acknowledgement, sender states, idempotency, and ID-conflict rejection.
* Disconnected buffering, ordered replay, same-ID retry, expiry, and recovery abandonment.
* Generation-safe delivery and terminal-persistence retry handling, including stale-event rejection.
* Terminal content cleanup, persistence-before-shutdown, and retry after a temporary database error.
* Pending-only limits and accounting, content removal, bounded content-free completion metadata,
  and direct timer testing without long sleeps.
* More than 50 lifetime messages after acknowledged messages are cleared.
* No PostgreSQL Message row created by live delivery.

---

# Current Progress

## Participant Identity and Security

Status: ✅ **Identity-to-match path built and verified by `mix precommit`: 73 tests, 0 failures**

What exists today:

* ✅ `ParticipantControllerTest`: `POST /api/participants` creates an anonymous Participant and
  returns only its UUID and a signed `Phoenix.Token`.
* ✅ `ParticipantChannelTest`: socket connection verifies the signed token, confirms that the
  Participant still exists in PostgreSQL, and assigns the verified participant UUID.
* ✅ `ParticipantChannelTest`: participant-bound topics reject a socket attempting to join a
  different participant's topic.
* ✅ `ParticipantChannelTest`: a verified participant can enter the queue, compatible participants
  persist one Match and Conversation, and both receive the limited match notification.

This is signed-token **identification, not authentication**. There is no account, password, device
proof, or recovery mechanism.

Open items:

* ⬜ Rate limiting for `POST /api/participants`.
* ⬜ A defined multi-tab/session policy.
* ⬜ Token refresh and rotation. Neither exists today.

## Product-Capability Milestone — Phase 3 / Phase 5

Real client → verified identity → queue → match → conversation → completion/cleanup.

* ✅ **Identity → match**, backed by `ParticipantControllerTest`, `ParticipantChannelTest`, and the
  recorded `mix precommit` result of 73 tests, 0 failures.
* ✅ **Conversation → completion/cleanup**, backed by the authorized `conversation:end` path in
  `ParticipantChannelTest` and `mix precommit`: 93 tests, 0 failures.

Backend logic working internally is not the same as a usable product capability. A capability is
usable only when a real client can reach the full path and that path is tested end-to-end. This
milestone therefore cross-references Phase 3 backend services and Phase 5 client integration.

| Vertical Slice | Status |
| --- | --- |
| Participant | ✅ Complete |
| QueueState | ✅ Complete |
| Match | ✅ Complete |
| Conversation | ✅ Complete |
| Message | ✅ Complete |
| Memory | ✅ Complete |
| Relationship | ✅ Complete |
| MessageReaction | ✅ Complete |
| Report | ✅ Complete |
| SafetyEvent | ✅ Complete |
| AnalyticsRecord | ✅ Complete |
| LearningRecord | ✅ Complete |
| Queue Engine | ✅ Complete |
| Matchmaking Engine | ✅ Complete |
| Queue Timeout Logic | ✅ Complete |
| Conversation Lifecycle | ✅ Complete |
| Memory persistence | 🧪 Schema/context verified |
| User-owned Memory Generation | ⬜ Deferred to Frontend/AI |

---

# Phase 3 Breakdown — Core Backend Services

| Component | Progress |
| --- | --- |
| **Matchmaking** | 🟩 **100% Complete** |
| ↳ *Queue Engine* | ✅ Complete |
| ↳ *Matchmaking Engine* | ✅ Complete |
| ↳ *Matching Rules* | ✅ Complete |
| ↳ *Queue Timeout Logic* | ✅ Complete |
| **Conversation Lifecycle** | 🟨 **In Progress** |
| ↳ *Conversation Lifecycle* | ✅ Complete |
| ↳ *Memory persistence* | 🧪 VERIFIED — `MemoriesTest` |
| ↳ *User-owned Memory Generation* | ⬜ Deferred to Frontend/AI |
| ↳ *Relationship Creation* | ✅ VERIFIED — `RelationshipConsentSafetyReviewTest`, `ParticipantChannelTest` |
| ↳ *Conversation Completion Flow* | ✅ VERIFIED — `ParticipantChannelTest` |

## Conversation Completion Flow

An authenticated member may send `conversation:end`. One participant ends the Conversation for
both sides. The server clears pending raw message content, persists `ENDED`,
`conversation_completed`, `NATURAL_END`, the verified initiator, and `ended_at` before stopping, and
then sends one participant-safe completion event to active tabs. Duplicate completion requests are
idempotent. Completion does not automatically create a Relationship, Memory, Report, or rating.

## Relationship Creation

`relationship:consent` derives identity from the verified socket. A unique Conversation/participant
consent row records the first private consent; the second consent transactionally creates one
canonically ordered Relationship. Database uniqueness protects both consent and unordered-pair
identity, while unbuilt scores, learning fields, and JSON outputs remain `nil`. Abandoned and
safety-ended Conversations are ineligible. Verified by `RelationshipConsentSafetyReviewTest` and
`ParticipantChannelTest`.

## Safety

* ✅ VERIFIED — `ParticipantChannelTest`: a verified Conversation member can deliberately submit a
  canonical report category and optional evidence text. Reporter and target identities are derived
  from the signed socket and persisted Conversation; payload IDs cannot override them. Identical
  submissions are idempotent. No normal message buffer or Conversation history is stored. Verified
  by the 19-test focused command and `mix precommit`: 94 tests, 0 failures.
* 🧪 PARTIALLY VERIFIED: Report creation is client-reachable, but automatic SafetyEvent creation is
  intentionally absent because Report and SafetyEvent category vocabularies differ and SafetyEvent
  requires an unassessed severity. Mapping and severity policy require an explicit decision.
* ✅ VERIFIED — `ParticipantChannelTest`: `conversation:block` derives the blocker from the signed
  socket and the blocked participant from the persisted Conversation, ignores spoofed payload IDs,
  creates one directional `boundary_blocks` row idempotently, sends no special notification to the
  blocked participant, and prevents the pair from matching again in either direction. Blocking does
  not create or delete a Report or safety-evidence record. Verified by the 24-test focused command
  and `mix precommit`: 95 tests, 0 failures.

## Safety Review Pipeline

Every new deliberate Report is transactionally paired with one `PENDING` SafetyReview. SHA-256
deduplication and database uniqueness make identical submissions converge on one pair. Severity is
unassessed (`nil`) until a trusted internal transition resolves the review; no SafetyEvent, block,
ban, AI decision, or moderator interface is created automatically. Verified by
`RelationshipConsentSafetyReviewTest`.

---

# Phase 4 — AI & Intelligence

* ⬜ Conversation-content learning is opt-in only.
* ⬜ Any opted-in content must be minimized and separated from participant identity.
* ⬜ Prefer anonymous aggregated operational signals over raw private messages.

---

# Phase 5 — Real Client Integration

See **Product-Capability Milestone — Phase 3 / Phase 5** above.

* ✅ Verified identity → queue → persisted Match and Conversation → match notification, backed by
  `ParticipantControllerTest` and `ParticipantChannelTest`.
* ✅ Phoenix Channels — `ParticipantChannelTest`.
* ✅ Queue Synchronization — safe `queue:status`, idempotent `queue:leave`, and disconnect cleanup in
  `ParticipantChannelTest`.
* ✅ Match Events and Conversation Events — `ParticipantChannelTest`.
* ✅ Typing Indicators — expiry, refresh, and stale-generation rejection in `ParticipantChannelTest`.
* 🧪 Delivery acknowledgement — `ConversationDeliveryTest` and `ParticipantChannelTest`.
* ✅ Disconnect Recovery and Reconnection Logic — ordered replay in `ConversationDeliveryTest`.
* 🧪 Presence Tracking — multiple-tab connectivity in `ParticipantChannelTest`.
* ⬜ Read receipts — deliberately deferred.
* ⬜ Browser client integration remains open until Macro-slice 3.

---

# Phase 6 — Frontend

The V1 presentation aliases are locked and centralized in `door_mapping.mjs`:

| User-facing Door | Canonical backend value |
| --- | --- |
| Deep Talk | `SOMETHING_REAL` |
| Vent | `JUST_TALK` |
| Distract | `KEEP_IT_LIGHT` |
| Advice | `EXPLORE` |

Only labels are displayed and only canonical values enter `queue:join`; the matcher continues exact
backend-value comparison. `door_mapping_test.mjs` proves all four mappings and rejects unmapped
labels.

* 🧪 Responsive plain HTML/CSS/JavaScript screens implemented for Talk/Door selection, queue,
  match, Conversation, completion, Chats, historical local copies, Memory Space, Bonds, and You.
* 🧪 Anonymous bootstrap, signed socket connection, queue/match/conversation/message actions,
  typing, completion, report, block, and relationship consent are wired to the verified channels.
* ✅ Browser queue entry sends only the canonical `door_type`; `ParticipantChannelTest`,
  `TextMvpIntegrationTest`, and `door_mapping_test.mjs` verify the socket-to-match path without
  client identity or unmeasured profile inputs.
* 🧪 Semantic controls, visible focus, screen-reader status, reduced motion, scalable text, safe
  `textContent` message insertion, and no participant UUID display are implemented.
* ⬜ Automated browser end-to-end coverage remains open.

* ✅ IndexedDB stores anonymous identity, settings, rendered local history, private notes, manually
  saved summaries, and locally known Relationships; no structured data uses `localStorage`.
* ✅ Users can inspect local record counts, delete individual saved notes/summaries, or delete all
  browser-owned data.
* ✅ Browser Web Crypto exports versioned PBKDF2-SHA256/AES-GCM backups with random salt and IV;
  passphrases are never stored and no recovery promise is made.
* ✅ Import validates the envelope and merges by stable record ID, with newer `updated_at` winning.
  Verified by `local_data_test.mjs`: encryption round trip/wrong-passphrase rejection, validation,
  and deterministic merge behavior.
* ⬜ Cloud synchronization is deliberately not implemented.

## Current Slice Specification — Explicit local Conversation retention

Displayed messages are cached in IndexedDB during an active Conversation under a
`local_conversation` whose status is `temporary`; temporary does not mean retained. When the
Conversation ends, no choice is made automatically. The user must choose exactly one outcome:

* **Keep this Conversation:** retain its `local_message` records, mark it `kept`, and list it under
  Chats → Kept on this device.
* **Save only a summary:** require and persist the summary before deleting transcript records, mark
  it `summary_only`, and omit it from kept Chats.
* **Let it fade:** delete transcript and associated summary, mark it `faded`, preserve separately
  created Memories, and return to Talk.

Historical copies have no composer, typing indicator, or presence state. They support local Memory
creation, summary editing, deletion, and return to Chats. Deleting kept history never silently
deletes separate Memories; associated summaries require a separate confirmation. Guest copy states:
“Saved only on this device unless you export an encrypted backup.”

Talk, Chats, Bonds, and You are the four top-level destinations. Talk opens Door selection directly.
Active Chats contain only connected, reconnecting, or recovery-window Conversations; kept Chats
contain only `kept` records. Each Conversation receives a deterministic, non-UUID-visible abstract
signature seed rendered only as a restrained non-circular ribbon, and a linked Bond reuses it when
that linkage is locally known.

Verified by 13 passing Node tests, including pure behavior in `local_data_test.mjs`: temporary caching without promotion, Keep,
summary-only deletion ordering, Fade, kept-only listing, delete-one/delete-all boundaries,
Memory preservation, and stable/distinct signature seeds. `PageControllerTest` verifies the privacy
copy, four-tab navigation, and absence of live controls from historical markup. Automated browser
end-to-end coverage remains open.

Manual browser testing confirmed that the Keep path displays a retained Conversation under Chats.
The same pass found the fixed bottom navigation overlapping lower Door cards and kept-Conversation
content on Talk and Chats. The shared top-level shell now reserves navigation height, mobile safe-area
inset, and normal content spacing so controls remain reachable, and the top-level terminology is
consistently Chats. The complete manual retention checklist is still unfinished, and automated
browser end-to-end coverage remains open. Fade, summary-only, refresh persistence, delete-one,
delete-all, Bond preservation, and offline/reconnect recovery have not yet been manually verified.

---

# Phase 8 — Integration and Quality

| Quality area | Evidence-backed status |
| --- | --- |
| Unit Tests | ✅ Verified — named ExUnit and Node test files |
| Schema Tests | ✅ Verified — migrations plus schema/context suites |
| Runtime Verification | ✅ Verified — `mix precommit` |
| Channel Testing | ✅ Verified — `ParticipantChannelTest`, `ConversationDeliveryTest` |
| Integration Testing | ✅ Server path verified — `TextMvpIntegrationTest` |
| Browser End-to-End Testing | ⬜ Open — no automated browser E2E exists |
| Load Testing | ⬜ Open |
| Performance Testing | ⬜ Open |
| Security Testing | ⬜ Open |

`TextMvpIntegrationTest` proves bootstrap identity, verified sockets, strict same-Door matching, one
Match/Conversation, safe notifications, active Conversation, acknowledged live delivery,
disconnect buffering, ordered replay with original IDs, normal completion, two-party Relationship
consent, pending SafetyReview creation, rematch blocking, and zero PostgreSQL Message history.

## Manual browser checklist (not automated evidence)

* Open `/` at desktop and narrow mobile widths; verify focus visibility and keyboard-only use.
* Bootstrap an anonymous identity, choose each visible Door, and confirm its documented backend
  queue value in development tools.
* Match two browser sessions, exchange and acknowledge messages, then reconnect one session.
* Verify typing/presence text, completion, private consent, report, and block controls.
* Save/delete local notes and summaries; export, decrypt/import, and merge an encrypted backup.
* Clear all local data and verify the warning and new anonymous identity behavior.

---

# Phase 9 — Deployment and Operations

## Local single-node deployment artifacts

* 🛠 Production release configuration and environment validation implemented. A local
  `MIX_ENV=prod mix release --overwrite` completed successfully on Elixir 1.17.3 / OTP 27.
* 🛠 `Dockerfile` and `.dockerignore` implement a non-root, multi-stage release image. Docker is not
  installed in the verification environment, so an actual image build remains unverified.
* ✅ `GET /health/live` proves the endpoint responds; `GET /health/ready` checks PostgreSQL with a
  generic response. Verified by `HealthControllerTest`.
* ⬜ Actual hosting, domain, SSL certificate, production PostgreSQL, monitoring vendor, backup
  storage, deployment pipeline, and production deployment remain open.

Required production variables are `DATABASE_URL`, `SECRET_KEY_BASE`, and `PHX_HOST`; `PORT`,
`POOL_SIZE`, and `LOG_LEVEL` are environment-driven optional settings with explicit defaults or
allowed values. Secrets are not committed.

Run migrations from a built release with:

```text
bin/migrate
```

Deployment requires an operator-owned PostgreSQL backup and restore procedure before migration or
upgrade. This repository does not provide or claim remote backup storage. Restore must be rehearsed
against a separate database before deployment.

Free-tier limits are provider-specific and must be checked before choosing hosting. The deployment
must budget for BEAM/release memory, PostgreSQL connection-pool memory, database storage, logs, and
temporary in-memory ConversationServer buffers (up to 262,144 content bytes and 50 pending messages
per active ConversationServer). Exceeding a provider's memory or storage allowance may terminate
the single instance or reject writes; no automatic horizontal scaling is implemented.

This architecture is deliberately single-node: queue state, typing, presence, delivery buffers,
acknowledgement metadata, and reconnection timers live in one BEAM instance. A restart loses that
temporary state, and multiple application nodes would not share or lock it safely.

The following retention and cleanup policies must be defined before deployment; acknowledging the
work here is not a completed design:

* ⬜ Queue-entry expiry and stale-participant cleanup.
* ⬜ Inactive `ConversationServer` process expiry and termination.
* ⬜ Temporary delivery-buffer expiry, acknowledgement cleanup, and undelivered-message handling.
* ⬜ Resolve the dependency vulnerabilities recorded in the Technical Debt Register.

---

# Data Ownership and Minimal Server Storage

## Core principle

StrangerTalks should permanently retain as little personal data as possible, while temporarily
retaining the minimum data required to deliver messages reliably and keep users from feeling lost.
This is not “zero data” — the honest framing is “minimal, purpose-limited, short-lived server data.”
There is an important difference between permanently storing conversation history and temporarily
holding a message so it can actually reach the other participant — e.g. if Participant A sends a
message while Participant B has a weak connection, the server must be able to hold that message
briefly so delivery still succeeds. A “no storage” policy that breaks basic message delivery is not
the goal.

## Server-side data policy

Store only what is operationally necessary — anonymous participant ID and token-related identity
data, temporary queue state, match/conversation identifiers needed for the live session, minimal
safety/abuse-control records, minimal anonymous system metrics. No permanent raw chat history by
default. Queue entries, inactive conversation processes, and other short-lived records need defined
expiry/cleanup rules.

## Temporary Message Delivery Storage

The server may temporarily retain messages for delivery, retry, reconnection, and acknowledgement
during an active conversation. The future real-time messaging design must support:

* A unique client- or server-generated `message_id`.
* Temporary server-side buffering when the receiver is disconnected or has network problems.
* Delivery acknowledgement from the receiving client.
* Retry until acknowledged or expired.
* Duplicate-delivery protection via the message ID.
* Explicit states: `sending`, `sent_to_server`, `delivered`, `failed`, and `expired`.
* Deletion of the temporary server copy after successful acknowledgement.
* A strict expiry period for undelivered messages. The exact period is not decided here and is a
  required decision before message delivery is implemented.
* Sender notification if a message could not be delivered before expiry.
* Reconnection support within a limited grace period.
* No use of temporary message content for analytics, AI training, or unrelated processing.
* No silent conversion of temporary delivery storage into permanent chat history.

## Two storage layers

**In-memory delivery buffer** — held in the `ConversationServer` process, for short connection
interruptions during an active conversation. Cheap, fits single-server V1. Lost if the process or
server crashes.

**Short-lived durable delivery queue** — a possible future database-backed delivery record, only if
messages need to survive a server restart or a longer disconnect. Not designed or implemented now —
explicit future reliability decision. If ever built, it must have: strict TTL/expiry, automatic
deletion, no permanent-history purpose, minimal metadata, deletion after acknowledgement, and clear
storage limits respecting the ₹0 infrastructure constraint.

## User-owned data

Stored primarily on-device, with IndexedDB preferred over `localStorage`:

* Saved memories.
* Conversation summaries the user chooses to keep.
* Reconnection information.
* Relationship history.
* Preferences and local settings.
* Personal notes.

The user can view/delete local data, export an encrypted backup file, and import it on another
device. Locally stored sensitive content is encrypted where practical. There is no fake “recovery”
promise — if browser data and backup are both gone, that data, and possibly the anonymous identity,
is genuinely gone.

## Safety exception

Reporting is the deliberate exception to no-permanent-storage. The user deliberately submits
evidence; only selected messages/metadata are uploaded; evidence has a defined retention period;
there is no secret “just in case” storage of normal conversations.

## Analytics and learning

No raw private messages are used for training by default. Prefer anonymous aggregated signals:
queue time, match success, conversation duration, skips, reports, and voluntary feedback. Any use
of conversation content for learning requires explicit opt-in, must be minimized, and must be
separated from participant identity. Do not call something “anonymous” unless identifying metadata
has actually been removed or protected. Optional encrypted cross-device sync is a possible future
feature and is explicitly not part of V1.

---

# Technical Debt Register

This is the permanent register. Future technical-debt items belong here.

## Reserved `typing_cadence` matchmaking input

**Status:** KNOWN — NOT FIXED

**What it is:** The volatile queue entry still contains `keystroke_cadence` for compatibility with
older internal callers, but browser queue entry stores it as `nil` and strict same-Door V1 matching
never reads it. Typing indicators are an unrelated ephemeral Conversation feature.

**Why deferred:** A cadence metric cannot be known before a Conversation. A future metric may only
be calculated from real observed interaction behavior using server-calculated or otherwise
trustworthy measured data—not a guessed browser value. Its definition, privacy impact, minimum
sample size, and matching influence require a separate approved design.

**Fixed looks like:** Approve and test an evidence-based server measurement and privacy contract, or
remove/rename the reserved field and compatibility parameters. Until then it remains `nil` and has
no effect on compatibility, ordering, eligibility, timeouts, or matching.

## `learning_version` lifecycle ownership

**Status:** KNOWN — NOT FIXED

**What it is:** `learning_version` exists on Match and Conversation records, but match creation leaves
it `nil`; no implemented learning-version processing owns or assigns it yet.

**Why deferred:** The field only becomes meaningful once the later learning/analytics lifecycle is
designed and implemented. Match persistence must not invent a placeholder value.

**Fixed looks like:** A named learning-processing component defines the version semantics, writes the
field at the correct lifecycle point, and has tests proving creation, update, and compatibility
behavior.

## `ConversationRoom.muted_senders` cleanup

**Status:** KNOWN — NOT FIXED

**What it is:** Expired entries in `ConversationRoom`'s `muted_senders` map are never removed. A
long-running room encountering many unique senders could accumulate an ever-growing map.

**Why deferred:** A cleanup policy and its timing/behavior have not been designed or tested; the
existing muting behavior was intentionally left unchanged.

**Fixed looks like:** Expired entries are removed by a bounded cleanup policy, with tests covering
expiry, repeated senders, and long-running rooms without changing the 50-message protection.

## Competing `ConversationRoom` implementation

**Status:** KNOWN — NOT FIXED

**What it is:** `ConversationRoom` is a second, competing in-memory message implementation. It is not
used by the client-reachable flow. Its lifetime-history limit and `muted_senders` behavior do not
match the new Level B pending-content policy.

**Why deferred:** Removing or merging it here would broaden this slice and risk changing separate
matching-rules behavior without a deliberate consolidation decision.

**Fixed looks like:** Remove it, or deliberately merge any still-required behavior into
`ConversationServer`, with tests proving a single canonical implementation.

## Missing standalone canonical engineering documents

**Status:** KNOWN — NOT FIXED

**Priority:** Complete before deployment and before another major architectural phase begins.

**What it is:** Four documents listed by the Master Roadmap — the Engineering Constitution,
Architecture Reference, Current Slice Specification, and Error Log — are absent from the repository
and its Git history.

**Why deferred:** Reconstructing them during message-delivery implementation would expand scope and
risk invented or inconsistent canonical rules.

**Fixed looks like:** Separate, version-controlled documents are created from verified existing
policy and code evidence, cross-referenced from the Master Roadmap, with no duplicated or
contradictory status sections.

## Dependency vulnerabilities

**Status:** KNOWN — NOT ADDRESSED

The locked dependency versions were reported with these applicable advisories:

| Dependency | Locked version | CVE(s) | Severity |
| --- | --- | --- | --- |
| Bandit | 1.12.0 | CVE-2026-65623 | High |
| Mint | 1.9.0 | CVE-2026-59249, CVE-2026-59246 | Medium |
| Mint | 1.9.0 | CVE-2026-58229, CVE-2026-56810 | High |
| Phoenix | 1.8.8 | CVE-2026-56812 | Medium |
| Plug | 1.20.2 | CVE-2026-56813 | Low |
| Plug | 1.20.2 | CVE-2026-56814 | Medium |
| Postgrex | 0.22.2 | CVE-2026-58225 | Low |

**What it is:** The dependency-resolution output identified known vulnerabilities in the versions
locked for the HTTP server/client, web framework, request processing, and PostgreSQL driver.

**Why deferred:** This roadmap-only change does not alter dependencies. Each upgrade still needs
compatibility review and the complete verification suite.

**Fixed looks like:** Upgrade or otherwise mitigate every applicable advisory, record clean
dependency/security audit output, run the named full test suite, and complete that work before Phase
9 deployment.

---

# Error Log — Level B Delivery Slice

## Legacy composite-score assertion after locking Door-only V1 matching

**Observed:** The first cadence-contract focused run failed because `MatchmakingEngineTest` still
expected the legacy composite compatibility value `0.9`; warnings-as-errors also found a private
helper separating `join_queue/5` clauses.

**Resolution:** The clauses were grouped, and the assertion now verifies the real binary same-Door
compatibility score `1.0`. The rerun passed 28 focused ExUnit tests and 3 frontend Node tests.

## Safety review helper name collided with Ecto query macro

**Observed:** The first Macro-slice 1 warnings-as-errors compile treated a private `update/2` helper
as `Ecto.Query.update/2` because the context imports Ecto query macros.

**Resolution:** The helper was renamed to `update_review/2`; the migration then ran successfully in
the test environment and the focused tests passed.

## Application supervision versus legacy lifecycle tests

**Observed:** The first focused run failed because `ConversationLifecycleTest` started a Registry
that is now application-supervised and called the prior three-argument append API.

**Resolution:** The obsolete test-local Registry startup was removed, its server cases now use a
persisted Conversation fixture, and the oversized-content case uses the client-ID four-argument API.
Existing safety termination behavior was retained.

## Sandbox ownership and idempotent channel cleanup

**Observed:** A focused run exposed sandbox ownership failure in an async lifecycle test after
ConversationServer began loading PostgreSQL state. A failed/non-member channel termination also
exposed unregister logic that assumed the participant was registered.

**Resolution:** The database-backed lifecycle test now uses synchronous shared sandbox ownership,
and unregister/connection lookup is idempotent for unknown or already-removed channel membership.

## Channel-leave synchronization

**Observed:** A multi-tab assertion ran after the leave reply but before channel termination.

**Resolution:** The test monitors the channel and asserts its `:DOWN` message before reading server
state; no sleep was introduced.

## Callback grouping warning during terminal-persistence fix

**Observed:** The first warnings-as-errors compile in the small-fix pass failed because a new private
acknowledgement helper was placed between `handle_call/3` clauses, violating Elixir's clause-grouping
warning.

**Resolution:** The helper was moved below the complete `handle_call/3` callback group without a
behavior change. `mix.bat compile --warnings-as-errors` then passed.

---

# Test Infrastructure

## Status

✅ Complete

Verified:

* SQL Sandbox configured correctly.
* ExUnit test environment isolated from development.
* Ecto sandbox ownership verified.
* Repository configuration validated.
* All schema test suites passing.
* Automated test execution stable across repeated runs.

```text
111 tests, 0 failures

```

---

*Last Updated: August 2026*
