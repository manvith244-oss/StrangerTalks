# TEAM 2B — Hangouts SEC-001 decision record (proposed, NOT APPROVED)

Date: 2026-10-08
Repository: manvith244-oss/StrangerTalks
Evidence base: main `5058fc5c27045c008e1f1f8d66eb3d58aba2b00e`
Status: **DECISION REQUIRED — no implementation or production modification authorized**

## Verified behavior

1. Approved Hangouts V1 design (`docs/hangouts-v1-design.md`) explicitly introduced persisted room messages, ordered by authoritative sequence, with a separate Hangouts report authority. This was an intentional architecture decision, not a random accidental write.
2. `HangoutChannel.handle_in("message:send")` -> `RoomServer.send_message` -> `Hangouts.append_message` -> `Repo.insert(HangoutMessage)`. PostgreSQL stores message body, room ID, membership ID, client message ID, sequence and timestamp. `HangoutMessage.max_body_bytes/0` is 16,384.
3. `Hangouts.end_room/1` marks a room ENDED and timestamps it; it does not delete messages. `RetentionPolicy.v1/0` and `RetentionCleanup.run/1` have no Hangouts category or TTL. **SEC-001 remains OPEN on the audited SHA.**
4. `RoomServer` sends a message after successful database append, then broadcasts `message:new`; duplicate client IDs are checked by querying the stored message and comparing the body. Per-room sequence is persisted on the room row. A database body is therefore currently used for exact idempotency-conflict semantics, not only for transcript/history.
5. `RoomServer` reconnects with `Hangouts.room_snapshot/2`: current room sequence, membership and content state; current `snapshot/2` does **not** include a replay of prior message bodies. `hangouts.mjs` accepts optional `snapshot.messages`, but runtime snapshot does not appear to populate them. Verify behavior in a real browser before removing persistence; do not assume full-history replay is a requirement.
6. `hangout_reports` separately stores optional reporter-supplied evidence up to 4,096 bytes. A report has SUBMITTED/UNDER_REVIEW/RESOLVED/DISMISSED states but no Hangouts-specific automated cleanup or demonstrated human review tool. It does not automatically capture whole-group transcripts.
7. Supabase `vgfnrcqrnryauhzfgseh` read-only inventory on 2026-10-08 found 0 rooms, 0 messages and 0 reports *in that Supabase project only*. This does **not** prove there are no historical rows on the running Render production database, whose connection has not been established.
8. Verified foreign keys: `hangout_messages.room_id` and `membership_id` cascade on parent deletion; `hangout_reports.room_id` also cascades; `hangout_reports.reporting_participant_id` cascades; reported-participant deletion sets NULL. Deleting rooms or reporters without a safety retention plan can silently delete report evidence.
9. `priv/static/index.html` Hangouts ended state says "Messages and temporary identities from this room have expired." This is currently not a guaranteed truth.
10. No confirmed Hangouts age-entry control or human-review ownership was found. `docs/hangouts-v1-design.md` calls for an 18+ policy but this is not runtime enforcement.

## Options under founder consideration

| Dimension | A — Ephemeral message authority | B — Bounded short-lived PostgreSQL messages | C — Disable Hangouts for beta |
|---|---|---|---|
| Ordinary privacy | No durable ordinary bodies if implemented correctly; volatile crash loss | Defined temporary storage and background purge; temporary DB/backup exposure must be disclosed | Prevents new public Hangouts ordinary storage |
| Behavior | Live messages work; replay after crash/loss limited to designed ephemeral window | Existing delivery and duplication semantics mostly preserved until expiry | Visitors cannot enter group chat; 1:1 remains |
| Reports | Explicit participant excerpt remains separate with bounded retention | Same; never retain full transcript by default | Existing reports must still follow approved lifecycle |
| Reconnect | Requires sequence/idempotency authority without durable body and exact test | Existing snapshot preserved; late duplicate behavior changes after expiry must be specified | Reject lobby join **and** room join/send; UI must not advertise feature |
| Crash | In-memory bodies lost; sequence survives only if metadata is durable | Temporary messages persist across crash until cleanup | No live public group state |
| DB/migration | Replace body authority; migration and legacy cleanup plan needed | TTL field or reliable cutoff query, scheduled cleanup, separate safety evidence lifecycle | No destructive migration required; feature gate code/config + tests |
| Verification burden | High: concurrency, recovery, replay, duplicate semantics, privacy | Moderate/high: TTL enforcement, cleanup/monitoring, FK-safe report preservation | Moderate: frontend and backend no-entry tests, runtime flag proof |
| Rollback | Complex where clients depend on message semantics | Moderate; reverting may restore indefinite persistence | Simple flag rollback **only after** future security gates satisfied |
| 2026-10-18 fit | Risky under short deadline | Possible only with owner-approved TTL, infrastructure cadence and extensive tests | Safest conservative beta fallback |

**Recommendation:** Option C for the Oct 18 global-access beta **if the founder cannot approve and verify a complete bounded Hangouts retention + moderation design**. Option B is the lower-change long-term candidate if the group product must remain in beta; no time limit has been approved here. Option A requires a deeper realtime review with Team 1 because message body comparison currently implements idempotency.

## Owner decisions needed (do not silently select)

- Is Hangouts part of the initial public beta, or disabled behind a true server-side gate?
- If enabled, choose A/B and explicitly set ordinary message expiry, crash/reconnect guarantees and duplicate-client-ID horizon.
- Decide the maximum lifetime of reporter-selected Hangouts evidence, open and finalized cases, and what to retain when room/guest rows expire. Require legitimate purpose, restricted access and deletion.
- Decide minimum permitted age and eligible launch jurisdictions with legal review; do not add sensitive ID/DOB collection by default.
- Assign a real human moderation owner, response coverage and escalation path; no assumed 24/7 service.
- Decide policy copy explaining separate 1:1 vs Hangouts retention, local/device data and possible backup residuals.

## No approval-dependent changes have been made

No production migration, deletion, release, permissions update, scheduler installation, feature disable or public-policy publication was executed.

## Safe implementation gates after approval

**If A:** coordinate with Team 1; replace stored bodies with a bounded volatile authority plus durable minimal sequence/idempotency metadata; test duplicate same/conflicting payloads, server crash, partial delivery, reconnect, concurrent sends, multiple participants, unapproved replay, post-room termination and memory exhaustion. Plan separate cleanup of legacy bodies only after explicit authorization.

**If B:** define immutable retention rule; add targeted ordered cleanup; use transactions/locking to avoid deleting active room content prematurely; explicitly design what duplicate messages do after expiry; avoid cascading report loss; verify exactly-once/idempotent repeated cleanup, retries, long-running jobs, failure alerting, safe clock cutoffs, backups and stale room transitions. Do not call periodic cleanup an absolute expiry guarantee unless out-of-window reads are independently blocked.

**If C:** add a single default-off production gate enforced at server lobby join, queue admission, room join, room send, safety actions as appropriate; preserve protective report access according to approved policy. Hide/label entry in UI; verify hostile clients cannot bypass by calling websocket topics directly; verify 1:1 paths unaffected. Do not assume a flag already exists.

### Proposed regression cases for all choices

- Unauthorized outsiders cannot read/submit message/report or spoof room identity.
- Active member message ordering and idempotent retries.
- Abrupt RoomServer termination and restart.
- Failed room formation and terminal room behavior.
- Same client message ID with different body before/after expiration.
- Concurrent cleanup versus send; active rooms still function.
- Exact cutoff edge cases, repeated cleanup, and failed cleanup alerts.
- Room/reporter deletion leaves approved safety evidence accessible to authorized reviewers only.
- Retained report evidence expires when approved; archival/backups disclosed truthfully.
- Same exact SHA passes targeted Hangouts, retention DB, safety, 1:1 privacy and JS/browser integration tests.

## Cross-team responsibilities

- Team 1: message order, duplicate processing, reconnection, crash recovery.
- Team 3B: truthful ended-screen copy, age/privacy UI and frontend feature gate.
- Team 4B: isolated staging, retention scheduler, alerts, backup horizon, Render DB discovery.
- Team 5B: beta-feature scope and safety/support public messaging.
- Central Command: founder product and retention decision, PR merge and launch authorization.
