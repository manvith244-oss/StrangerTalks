# Team 7 Privacy & Retention Cross-Team Handoff

Baseline: `585637924ff45933c7b35b0bc27719934907c70e`

Implementation lane: `team7/privacy-retention-2026-08-26`

This handoff contains engineering/product retention contracts only. It makes no legal-compliance claim.

## Team 1 — Queue authority and inactive Block lifecycle

### QueueState persistence guard

Current canonical matchmaking uses the in-memory QueueEngine `Agent` state and does not need durable `queue_states`. Team 7 now carries a regression proving a normal queue/match flow leaves the `queue_states` table at zero.

The dormant `MatchingRules.log_match_telemetry/4` API can still insert an `intent_vibe_vector` into `queue_states`. V1 policy forbids this durable readiness/vibe telemetry. If Team 1 finds any active production caller, the narrow required patch is to remove/guard that caller without changing queue fairness or matching authority.

Required invariant:

```text
canonical queue/match flow -> zero durable queue_states rows
```

### BoundaryBlock inactive-retention clock

Active BoundaryBlocks must never be deleted by retention cleanup. Current schema has `active_status` plus `timestamp`, but no dedicated deactivation timestamp. Team 7's cleanup therefore only treats an inactive block's existing lifecycle `timestamp` as cleanup age. Any future Team 1 unblock/deactivation path MUST atomically update that timestamp to the deactivation time before setting/with setting `active_status=false`; otherwise retention must fail safe and retain the row rather than guess its age.

## Team 3 — Legacy Messages / Reactions boundary

Direct inspection of `ConversationLifecycle.ConversationServer` found no normal live-path reference to the legacy `Messages` or `MessageReaction` persistence contexts. Team 7 now carries a real runtime regression that sends, acknowledges, and reacts through ConversationServer and then asserts:

```text
messages row count = 0
message_reactions row count = 0
```

Legacy schemas/APIs remain compatibility-only for now; Team 7 does not drop them blindly. Any future Team 3 change that routes ordinary live temporary Conversation content through these tables must be rejected or guarded before merge.

## Team 5 — Account / continuity deletion contract

V1 must have an explicit user account/continuity deletion path before unrestricted public launch. Team 5 owns the account-continuity implementation. Team 7's deletion contract is:

1. revoke all sessions;
2. disconnect/revoke Google provider link and immediately clear encrypted refresh-token material;
3. delete the remote encrypted sync file and local `account_sync_states` metadata using current proven sync-delete semantics;
4. hard-delete account-owned Reflections from the primary database;
5. delete account-owned Memories, except where a separate active safety authority requires minimal pseudonymous state;
6. remove private-account/continuity records;
7. sever ordinary account-linked relationship continuity according to current product semantics;
8. preserve only minimal pseudonymous safety authority when an active safety restriction/report genuinely requires it;
9. primary content removal should be immediate or completed by a bounded deletion transaction/job;
10. operator backups may retain the prior version for no more than 14 days.

Team 7's cleanup entrypoint already owns physical cleanup for expired/revoked account sessions, old OAuth attempts, expired operational grants/intents, and revoked Google-link metadata. Team 5 should integrate account deletion with those semantics rather than inventing a second retention clock.

## Team 6 — Exact privacy copy corrections

### Chats

Replace misleading device-only wording with:

> Saved on this device. If you enable encrypted Google sync or export a backup, an encrypted copy can exist elsewhere.

### Reflections

Use wording equivalent to:

> Your durable reflections, stored in your StrangerTalks account and visible only to you in the app.

Where appropriate, add the explicit qualifier:

> Account reflections are stored server-side and are not end-to-end encrypted.

Do not call Reflections E2EE unless the architecture actually changes later.

## Team 8 — Production operation contract

### Cleanup command

Team 7 exposes exactly:

```bash
mix strangertalks.retention
```

The command runs one bounded cleanup pass. Each category commits independently. A category failure does not roll back successful independent categories; the command exits non-zero when any category failed so operations can alert and retry. Re-running is intended to be safe and idempotent.

Team 7 does **not** choose or install the production schedule. Team 8 must choose a cadence frequent enough to meet the approved physical-cleanup guarantees, especially the 24-hour operational-record requirement.

Never let scheduling remove:
- ACTIVE/PENDING/PAUSED or otherwise recoverable Conversations;
- active BoundaryBlocks;
- active safety investigations;
- active accounts or active Relationships;
- rows still required by deterministic safety authority or foreign-key dependencies.

### Backups

Production PostgreSQL backup policy:
- 14-day rolling retention;
- encrypted at rest;
- access controlled;
- automatic rotation/deletion;
- no indefinite laptop copies;
- no plaintext upload to arbitrary storage;
- restore drills only against isolated databases.

User deletion may therefore remain recoverable from an operator backup for at most 14 days; product copy must not promise physical erasure everywhere instantly.

### PostHog, if enabled

- 90-day maximum V1 product-analytics retention;
- explicit allowlist events only;
- disable DOM autocapture and session replay on Conversation/private surfaces;
- never capture messages, Reflections, report text, media, or participant identifiers.

### Sentry, if enabled

- 30-day maximum V1 error-event retention where configurable;
- never capture message content, media/voice, Reflection text, report evidence, encryption keys, or OAuth tokens;
- verify the actual vendor-side configuration rather than relying only on source-side redaction.

## Authority dependency discovered by Team 7 — CLOSED Relationship rows

Current matchmaking safety veto treats any bilateral `relationships.relationship_status = CLOSED` row as a no-rematch authority. Deleting that entire row after the 30-day rich-detail window could therefore silently weaken safety and permit rematching.

Team 7 does **not** change the approved 30-day rich-detail policy. Its cleaner removes rich Relationship fields after the boundary but retains the minimal CLOSED authority row while the current matching implementation depends on it.

First divergence:

```text
retention wants old ordinary CLOSED Relationship row gone
-> current MatchingRules.closed_relationship?/2 still uses that row as safety veto truth
-> physical row deletion would weaken deterministic safety authority
```

Team 1 (match safety veto) and Team 5 (Bond/relationship lifecycle) should jointly decide the narrow future representation of minimal no-rematch truth. Until that authority is separated, retention must fail safe and preserve the minimal row. This can also keep referenced participant/origin metadata alive through foreign-key dependencies; that is an explicit cross-team authority dependency, not permission to retain the rich Relationship payload.
