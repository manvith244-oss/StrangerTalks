StrangerTalks — Copilot Onboarding Notes

- What this repo is: an anonymous, ephemeral 1:1 conversation platform (StrangerTalks).
- Canonical stack: Elixir (>=1.15), Phoenix 1.8, OTP/GenServer, Ecto/Postgres, browser JS (IndexedDB for local persistence). Canonical namespace: StrangertalksNew.
- Realtime ownership: `ConversationServer` (in-memory authoritative delivery state), `ConversationChannel` (socket surface), `ParticipantChannel`, `UserSocket`.
- Source-of-truth priority: runtime code + tests > `config/PROGRESS.md` > README. Trust tests and channel/server code when in doubt.
- Git safety: working tree may be dirty. NEVER reset/restore/checkout/stash/commit/push/clean during audits or feature work unless Team 6 says so.
- Infrastructure rule: do NOT add new infra (Redis, Kafka, external queues, paid providers) without explicit Team 6 approval.
- Multi-tab: a participant may have multiple sockets/tabs; code uses channel registration + session visibility + delivery progress for multi-tab correctness. Prefer existing CAS/revision patterns and `epoch_id` + `sequence` semantics.
- Join vs sync: `join(... )` + `ConversationServer.sync_and_register_channel` is used to attach and receive an initial sync; `sync:reconcile` is used for timeline reconciliation — do not conflate these semantics.
- Privacy rule: product data (message content, reply snippets, pins, IDs, tokens) must NOT be logged, telemetered as diagnostic strings, or leaked into exceptions. Use reason codes and redacted format_status when required.
- Testing rule: run and extend the owning test surface first (channel behavior → channel tests, ConversationServer → ConversationServer tests, browser interactions → JS tests / Playwright). Focused tests before full regressions; run `mix precommit` only after local verification.
- Execution authority: Team 6 provides the frozen execution packet for features. If Team 6 instructions conflict with repository invariants, follow Team 6 unless it contradicts code/tests in a way that triggers STOP.

Keep this file short. Update only to add durable, high-value guidance — not transient feature state.

Permanent source-of-truth rule:
- `CURRENT CODE / TESTS` are authoritative for repository implementation reality.
- `TEAM 5 PROJECT STATE` and `TEAM 7` closure are authoritative for roadmap lifecycle labels (e.g., VERIFIED COMPLETE).
- `TEAM 6 EXECUTION PACKET` is authoritative for the active implementation assignment.

If these sources disagree, report the exact contradiction instead of silently reconciling.
