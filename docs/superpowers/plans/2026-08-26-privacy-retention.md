# Team 7 Privacy & Retention Implementation Plan

**Goal:** Implement the Command-approved StrangerTalks V1 privacy/retention policy at the exact audited release-prep baseline without scheduling production jobs, merging, or deploying.

**Baseline:** `585637924ff45933c7b35b0bc27719934907c70e`

**Lane:** `team7/privacy-retention-2026-08-26`

## Task 1 — Lock policy in code (TDD)

Files:
- Create `test/strangertalks_new/retention_policy_test.exs`
- Create `lib/strangertalks_new/retention_policy.ex`

Steps:
1. Add failing tests for every approved V1 duration and the zero durable transcript rule.
2. Run the dedicated exact-SHA Team 7 gate and record the expected RED result.
3. Implement named policy functions/constants in one module; no scattered retention literals.
4. Re-run focused policy tests to GREEN.

## Task 2 — Build bounded retention cleanup orchestration (TDD)

Files:
- Create `test/strangertalks_new/retention_cleanup_test.exs`
- Create `lib/strangertalks_new/retention_cleanup.ex`
- Create `lib/mix/tasks/strangertalks.retention.ex`

Behavior:
- `StrangertalksNew.RetentionCleanup.run/1` executes independently bounded categories, returns per-category results, and continues after one category fails.
- Each category is independently idempotent.
- The Mix task is the exact Team 8 scheduling handoff command; Team 7 does not schedule it.

Coverage:
- OAuth attempts: physical cleanup within 24h of expiry/consume.
- Sessions: physical cleanup 30d after expiry/revocation.
- Reconnect intents: physical cleanup within 24h of expiry/consume/cancel.
- Composer grants: cleanup within 24h of expiry/consume/terminal invalidation.
- Safety media: 30d default, active human review extends only to hard max 60d.
- Reports/reviews/events: remove rich evidence/notes/narrative on approved boundaries while preserving minimum active safety authority.
- BoundaryBlocks: active always preserved; inactive historical row only eligible after 30d lifecycle timestamp.
- Memories: hard purge soft-deleted rows after 7d.
- Relationship consents: terminal-conversation consent cleanup after 30d.
- Closed Relationships: purge rich relationship detail after 30d, without weakening active safety authority.
- Conversations: delete eligible terminal metadata after 30d, never ACTIVE/PENDING/PAUSED/recoverable or safety/bond-dependent rows.
- Matches: delete eligible terminal metadata after 30d, never rows still required by Conversation/Relationship/Safety authority.
- Analytics: delete rows older than 90d.
- Revoked Google links: cleanup after 30d only when no active security/safety dependency exists.
- Guest participants: delete after 30d inactivity only when no Conversation/recovery/account/relationship/safety dependency exists.

## Task 3 — Add privacy persistence regressions (TDD)

Files:
- Create `test/strangertalks_new/privacy_persistence_guard_test.exs`

Attacks:
- normal live send/reply/edit flows create zero `messages` rows;
- normal live reactions create zero legacy `message_reactions` rows;
- canonical queue/match flow creates zero durable `queue_states` rows;
- current V1 Agent/analytics path creates zero participant-linked `learning_records` rows.

If an active foreign-team write path is proven, do not rewrite it here; record exact first divergence and issue a narrow Team 1 or Team 3 patch packet.

## Task 4 — Safety media participant-read attack

Files:
- Extend Team 7 safety tests or create focused privacy access test.

Attack:
- prove no participant-authenticated route/context exposes `report_safety_media.media_bytes`.

## Task 5 — Dedicated exact-SHA gate

Files:
- Create `.github/workflows/team7-privacy-retention.yml`

Required checks:
- checkout exact identity;
- retention-policy tests;
- cleanup/adversarial tests;
- privacy persistence guards;
- Agent boundary tests;
- telemetry/log-redaction tests;
- relevant account/continuity tests;
- relevant JS privacy/copy tests;
- `mix precommit`;
- `git diff --check`;
- empty `git status --porcelain`.

## Task 6 — Cross-team handoffs, not scope creep

Create `docs/TEAM7_PRIVACY_RETENTION_HANDOFF.md` with narrow packets:
- Team 1: queue-state persistence guard/removal if an active writer exists; future unblock must provide a trustworthy inactive-block lifecycle timestamp.
- Team 3: live `messages`/`message_reactions` guard if an active legacy writer exists.
- Team 5: account/continuity deletion contract and integration with operational cleanup.
- Team 6: exact Chats and Reflections wording corrections.
- Team 8: run command, fail-safe invariants, 14d backup rotation, PostHog 90d, Sentry 30d, vendor privacy verification.

## Task 7 — Verification and re-attack

1. Run focused Team 7 tests.
2. Run mandatory adversarial matrix.
3. Run Agent/telemetry/account/JS privacy regressions.
4. Run `mix precommit`.
5. Run `git diff --check`.
6. Prove empty `git status --porcelain` in CI.
7. Re-run cleanup twice and prove the second run is safe.
8. Prove a simulated category failure does not roll back or corrupt successful independent categories.
9. Review exact branch diff against baseline and report any remaining cross-team blocker rather than silently changing an approved retention duration.
