# StrangerTalks — Current Project Context (snapshot)

## Current checkpoint
1K — Conversational Polls (current roadmap checkpoint; Team 2 next owner)

## Verified completed features
## Verified completed features
1A — Reply / Quote: VERIFIED COMPLETE
1B — Emoji Reactions: VERIFIED COMPLETE (R0 + R1 closed)
1C — Session Pinned Messages: VERIFIED COMPLETE
1D — GIFs & Stickers: VERIFIED COMPLETE
1E — Voice Note Experience: VERIFIED COMPLETE
1F — Conversation Presence: VERIFIED COMPLETE
1G — Quiet Mode: VERIFIED COMPLETE
1H — Atmosphere / Chat Themes: VERIFIED COMPLETE
1I — Ambient Audio: VERIFIED COMPLETE
1J — Conversation Prompt Cards: VERIFIED COMPLETE
Ephemeral conversation UX: VERIFIED COMPLETE (ConversationServer doc + PROGRESS.md).

## Implemented / verification unclear
Voice privacy effects: PARTIALLY IMPLEMENTED (UI and warnings exist; server-side hooks require authoritative verification).

## Not found / deferred
Conversational Polls (1K): CURRENT ROADMAP FEATURE — TEAM 2 next owner (Feature Card not yet produced)

## Architecture map (concise)
Browser: `priv/static/assets/app.js` + IndexedDB (`local_data.mjs`) — manages composer, timeline rendering, local persistence, expressive picker, prompt cards, ambient audio, quiet mode.
Socket surface: `lib/strangertalks_new_web/UserSocket.ex`, `ParticipantChannel`, `ConversationChannel` — validates and rate-limits client actions.
Realtime server: `lib/strangertalks_new/conversation_lifecycle/conversation_server.ex` — ephemeral authoritative delivery, pending/completed buffers, epoch_id + sequence, replay/pruning, pins, reactions, voice-note ownership.
Persistence: Ecto/Postgres for Conversations/Participants/metadata; live messages are not persisted by `ConversationServer` (ephemeral only).
- Socket surface: `lib/strangertalks_new_web/UserSocket.ex`, `ParticipantChannel`, `ConversationChannel` — validates and rate-limits client actions.
- Realtime server: `lib/strangertalks_new/conversation_lifecycle/conversation_server.ex` — ephemeral authoritative delivery, pending/completed buffers, epoch_id + sequence, replay/pruning, pins, reactions, voice-note ownership.
## Next owner and action
Current next owner: TEAM 2 — ARCHITECTURE & SPEC LAB
Current next action: Create the 1K Conversational Polls Feature Card (do NOT implement until Team 2 delivers the card).

## Message model
- Client generates `client_message_id` / `message_id` (UUID). Server assigns `sequence` and `epoch_id` per `ConversationServer` instance. `sync:reconcile` returns messages after a `last_applied_sequence`. No `server_sequence` concept outside `sequence` + `epoch_id` pairing.

## Sync / reconnect
- `join` → `ConversationServer.ensure_started` → `sync_and_register_channel` provides initial sync payload. `sync:reconcile` used for incremental timeline reconciliation. Delivery progress uses `epoch_id` + `highest_contiguous_sequence`.

## Security / privacy rules
- Product data must not appear in logs/telemetry/exception strings. `format_status` redacts sensitive state. Telemetry uses reason codes and small metadata (e.g., message_type), not content.

## Tests and ownership
- Server/unit: ExUnit suites under `test/strangertalks_new/*` (conversation lifecycle, matchmaking, delivery, servers).
- Channel tests: `test/strangertalks_new_web/channels/*` (ParticipantChannelTest, ConversationChannel tests).
- JS/browser: `test/js/*` includes `browser_e2e_test.mjs` and focused feature tests (reactions, pins, voice notes, prompt cards, ambient audio). Playwright is the intended runner for E2E.
- Rule: extend the owning test surface first when changing behaviour.

## Current git/worktree reality (snapshot)
- Current branch: `full-source-recovery` (ahead). Working tree intentionally dirty with edits across `lib/` and `priv/static/assets/` and `config/PROGRESS.md`. DO NOT reset/restore/checkout/stash/commit/push/clean.

## Test commands
- `mix test` (server/unit). `mix precommit` runs compile+format+tests. JS tests live in `test/js/*.mjs` (Playwright/Node runner per repo docs).

## Known technical debt (high-level)
- Some features documented in PROGRESS.md have partial automation; browser E2E has historical Playwright usage but may require environment setup.
- Ephemeral server design trades durability for low infra; be cautious about adding persistent message stores.

## Next feature (repository evidence)
- Finish/verify Voice Privacy effects and their server-side hooks (UI present; server integration partially unclear).

---
This is a compact snapshot for future Copilot sessions. Update only when facts change or after major refactors.
