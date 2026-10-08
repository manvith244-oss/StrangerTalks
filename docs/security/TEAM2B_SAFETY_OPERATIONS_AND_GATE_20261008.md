# TEAM 2B — Safety operations, retention matrix, and release-security gate

Date: 2026-10-08; audit base: `5058fc5c27045c008e1f1f8d66eb3d58aba2b00e`
State: **PROPOSED OPERATIONAL RUNBOOK — NOT ACTIVATED; responsible humans not yet assigned**
No production action, migration, delete, customer-data extraction, or policy publication authorized.

## Evidence ledger and scope

- Current main confirmed by GitHub ref. PR #291 `940bd6f2327c53a48ff202460dcff21044a49071` is **OPEN/DRAFT**, unmerged, mergeable according to GitHub, no submitted reviews; all six previously recorded PR-head GitHub Actions workflows completed successfully. A live integrated SHA was not tested by Team 2B.
- Render `strangertalks-phoenix` is observed live at SHA `6f43cddab8812be9e0baaf80b2a6779410849948` (Sept 15), not current main; Sept 23 attempt at `fb73a1faec28393624af09da50845d84a3e5c128` was `update_failed`. Auto deploy off. In connected workspace, Render listed **no Postgres instances**, and previously documented instance `dpg-da4qk8rtqb8s738kla4g-a` returned NOT_FOUND. Do not confuse this with the Supabase database; production DB target and backup recovery must be investigated by Team 4B.
- Supabase `vgfnrcqrnryauhzfgseh` was active with RLS enabled on 32 application tables and zero Hangouts rooms/messages/reports at inspection. For `hangout_messages`, `hangout_reports`, `schema_migrations`, `has_table_privilege` returned no anon/authenticated SELECT privilege (and no selected write privileges). Supabase's generic `schema_migrations` RLS warning was inspected; the missing RLS alone is **not proof** of reachable public data in this observed permission model. Preserve hardening review without inventing exploitable access.
- `pg_cron` was not installed in the inspected Supabase project, `RetentionCleanup.run/1` runs only when called and `mix strangertalks.retention` is one-shot. No verified production schedule, last-success proof or alerting provided. **SEC-004 NOT VERIFIED.**
- `Hangouts.Safety.submit_report` persists optional reporter text (4,096 bytes max), client-id dedupe and target room identity in Hangouts table; block uses `MatchingRules.enforce_block` for future match veto. Current group continues even after block; UI discloses that. There is no demonstrated automated moderator queue or Hangouts report resolution workflow.
- 1:1 `Reports.submit_conversation_report` and `SafetyReviews` include durable report/review objects and status transitions. Code existence is NOT proof of an operator review queue, verified access control at a human tool, coverage or completed drill.
- `docs/hangouts-v1-design.md` explicitly records an intended 18+ Hangouts policy; no runtime age-entry enforcement has been verified. No collected DOB/ID is recommended without an approved privacy/legal decision.
- `priv/static/index.html` says Hangouts messages have expired on its end screen, but main stores Hangouts body rows durably without a cleanup rule. Need Team 3B correction/feature exclusion before publishing the claim.

## Retention/deletion matrix — engineering policy vs deployed enforcement

| Class | Storage | Policy/lifetime | Deletion or minimization | Exceptions / residuals | Gate |
|---|---|---|---|---|---|
| Ordinary 1:1 text | In-memory ConversationServer; browser local as user chooses | No ordinary **server-durable** transcript (`RetentionPolicy`: 0 seconds) | In-memory lifecycle/pruning | Explicit reporter-selected evidence separately durable; user-kept local copies | Existing code/test evidence only; final candidate retest |
| Hangouts ordinary bodies | `hangout_messages.body` in PostgreSQL | **NO approved TTL in current V1 policy** | No Hangouts cleanup; room end just status | Backups may preserve content; actual backup retention unverified | **SEC-001 OPEN** |
| Hangouts report excerpt | `hangout_reports.evidence` | Max input 4,096 bytes; **NO Hangouts-approved lifetime** | No Hangouts cleanup; cascading room/reporter deletion removes record | Must be preserved only for approved safety window; need separate parent lifetime design | **BLOCKED** |
| 1:1 report rich context | `reports.reporter_context` and links | Open: 180d; resolved/dismissed rich evidence: 90d | Central cleanup nulls rich fields | Other report metadata may remain; backup 14d operator-policy target | Scheduler unverified |
| 1:1 safety media | `report_safety_media` | Default 30d; active review hard max 60d | Central cleanup deletes | Legitimate active review bounded by hard cap | Scheduler unverified |
| Safety review rich notes | `safety_reviews` | 90d after final review | Central cleanup strips notes | Review metadata persists | Scheduler unverified |
| Safety event rich data | `safety_events` | 180d final event rich period | Delete/minimize per safety dependencies | Active blocks and actioned events can survive as structured metadata | Scheduler unverified |
| Inactive boundary block history | `boundary_blocks` | 30d after inactive | Central cleanup with open safety dependencies | Active block preserved | Scheduler unverified |
| Account sessions | hashed tokens in `account_sessions` | Cleanup 30d after expiry/revocation | Central cleanup | Raw tokens not meant to be stored in DB | PR #291 draft protects HTTP response caching |
| OAuth attempts | `google_oauth_attempts` | 10-minute logical; physical cleanup after operational 24h | Central cleanup | Backup residual per policy | Scheduler unverified |
| Guest/account metadata | `participants` and linked rows | Guest inactivity 30d under prerequisites; terminal match/conversation 30d | Central cleanup with dependency constraints | Preserve legitimate safety dependencies | Scheduler unverified |
| Local saved data | browser IndexedDB | User controlled | User deletion/browser cleanup | Exported copies under user control | UI must be truthful |
| Operator backups | External backup store, not verified | Policy target 14d | Operator-managed expiration | Restoration can temporarily reintroduce pre-delete bytes | Backup system unverified |

**Backups:** A 14-day operator policy target is in `RetentionPolicy`; that is not proof of configured backup expiration. Deletion claims need proof against actual backup provider and restoration semantics.

## Production retention execution acceptance — Team 4B owner

1. Identify actual production database, restore path, scheduler and run-as credentials; prove staging connects to a distinct disposable DB before any test writes.
2. Establish one instance of the cleanup runner on an approved timetable, no overlap (distributed lock or equivalent), bounded retries, error/exit-code capture, least-privilege DB role, and separate category metrics (success time, failures, rows handled, oldest expired row).
3. Test on synthetic isolated data: successful first pass, idempotent second pass, forced category error, retry, concurrency, clock boundary, and full report/active-room integrity.
4. Verify last successful execution via timestamped job telemetry; define overdue threshold and a real human receiving failure alerts. Never report scheduled merely because the Mix task exists.
5. Coordinate and separately validate any **approved** Hangouts category; do not add an arbitrary TTL just to satisfy scheduling.
6. Establish backup retention and a restore rehearsal; document inevitable residual horizon without exposing credentials or content.

## Age-eligibility closure — founder + Team 3B + legal

- Choose published minimum age and countries/jurisdictions. Separate 1:1 and Hangouts policy if required.
- Risk-proportionate default proposal: conspicuous 18+ eligibility statement with explicit server-recorded eligibility declaration before sensitive admission, no birth date/ID collection by default, and avoidance of user-profile age storage beyond minimally necessary consent metadata; **not represented as legally sufficient anywhere**.
- Test first-visit, returning guest, direct websocket, private/incognito browser, cookie clearing, alternate session, and feature-specific bypass. Disabling a frontend button alone is inadequate.
- Define repeat/minor-report handling, removal of unsafe access and retention of necessary abuse evidence. If a jurisdiction needs stronger assurance, restrict it pending counsel decision.
- **Status:** no verified age control; policy decision + enforcement + tests required.

## Human moderation — provisional roles, NOT staffing claims

Until assigned people exist, the **Responsible Moderator**, **Security Incident Lead** and **Communications Owner** are unfilled positions and the operational gate is **BLOCKED**. Do not promise a 24/7 SLA.

| Severity | Examples | Immediate operator action (only if authorized) | Escalation |
|---|---|---|---|
| S0 — imminent danger | Credible imminent threat, child exploitation material, active emergency disclosure | Preserve only specifically reported limited evidence; secure record, prevent further harm using authorized tools; avoid public identity exposure | Immediately reach assigned Security Incident Lead, competent emergency/legal channel as approved |
| S1 — high risk | Doxxing, coercion, severe repeated harassment, block evasion, sexual exploitation indicators | Prioritize human review; consider temporary feature restriction under existing permission model | Security Incident Lead + privacy/legal advisor |
| S2 — harmful conduct | Spam, scams, bullying, hate, unsolicited explicit content, malicious links/media | Review reporter context, evaluate counter-evidence, apply policy-authorized block/limitation | Responsible Moderator |
| S3 — routine | Misuse, duplicates, ambiguous or non-actionable reports | Triage, record reason, close or request clarification through safe channel | Responsible Moderator |

Case procedure: (1) retrieve incident by ID through authenticated, access-audited internal facility; (2) confirm evidence origin, reporter/target membership and deduplication; (3) classify severity; (4) limit view/export to assigned reviewer; (5) decide under approved policy with human authority; (6) enact supported enforcement without AI autonomous bans; (7) record decision, reviewer, rationale, timestamps and reconsideration route; (8) apply approved evidence retention; (9) close with incident communication where possible. Never copy raw transcripts into general tickets, dashboards, email or model prompts.

**Incident scopes to rehearse:** harassment, threats, exploitation/sexual content, scams, doxxing, minors, evasion, malicious media and group/platform abuse surge. For each, require named human and actual contact method before advertising safety coverage.

### Synthetic drill acceptance

- Submit a synthetic 1:1 report and Hangouts report in isolated DB.
- Prove it reaches a *real* accessible human review queue; no raw evidence in public logs.
- Authorize the reviewer, reject non-reviewer evidence access and record audit.
- Verify blocker and blocked person's future matching veto without mistaking it for immediate current-room separation.
- Force a failed report notification and demonstrate alert.
- Act and close; prove rich-evidence expiry and referential integrity.
- Establish emergency escalation through an assigned named person.
- **Not executed:** staging isolation and a human owner were not verified.

## SEC-005 source attribution

`StrangertalksNewWeb.AbuseSource.from_conn/1` uses `remote_ip` directly for nonprivate addresses, but falls back to the right-to-left parsed `x-forwarded-for` chain when `remote_ip` is private/local; it does not use an explicit configured trusted-proxy allowlist. Actual exploitability is conditional on ingress behavior and attacker control of headers, **not proven**. Team 4B must verify proxy normalization and direct service ingress, then Team 2B test IPv4/v6, malformed/multi-hop chains, spoofed headers and false grouping without weakening throttle policy.

## Truth table for public notices

| User-facing statement | Actual implementation | Discrepancy | Owner |
|---|---|---|---|
| "Normal messages are not permanently stored server-side" on 1:1 settings | Ordinary 1:1 server text is ephemeral, separately reported excerpts may be persisted | Narrow to 1:1 and clearly disclose safety exceptions | Team 3B + legal |
| Hangouts ended screen: "Messages and temporary identities from this room have expired" | Durable Hangouts message rows remain after ENDED, no TTL category | **Incorrect/unproven**; remove/change before public Hangouts | Team 3B + Team 2B |
| Hangouts 18+ design policy | Documented policy, no verified admission enforcement | Unenforced | Founder/legal + Team 3B |
| Hangouts Report/Block buttons | Report persists; Block protects future matches only; human follow-through not established | Explain review/response limits | Team 3B + Operations |
| Retention under a bounded V1 policy | One-shot task exists, schedule/alert unverified | Cannot promise automatic production purge | Team 4B |
| Privacy Policy / Terms / Community Guidelines | No published legal review/ownership established by this audit | Need approved, accessible and accurate notices | Founder/legal + Team 5B |

## Specific blockers / closure owners

| ID | Priority | Evidence | Gate/owner |
|---|---|---|---|
| SEC-001 | P1 confirmed | Durable group bodies, no cleanup; false end-screen claim | Founder chooses A/B/C; Team 1 + Team 2B + Team 3B verify |
| SEC-002 | P1 pending policy and technical proof | 18+ design statement but no verified age admission | Founder/legal, Team 3B |
| SEC-003 | P1 operations blocked | Reports persisted, no verified human operator queue, owner or drill | Founder/Moderation owner + Team 5B |
| SEC-004 | P1 operational | Cleanup one-shot, production cadence/alerts not established | Team 4B |
| SEC-005 | P2 conditional | `AbuseSource` trusts forwarding chain with private remote IP | Team 2B + Team 4B ingress proof |
| SEC-007 | P1 disclosure for Hangouts | Room-ended copy not backed by durable data deletion | Team 3B |
| INF-DB | P1 needs investigation | Render lists no PostgreSQL instances; historical Render DB id not found | Team 4B; verify actual live DB, do not infer outage or data loss |

## Release-verification contract

Run on a single exact integrated SHA, **not** branch names or PR green alone:
`mix test test/strangertalks_new/hangouts`,
`mix test test/strangertalks_new_web/hangout_channel_test.exs`,
`mix test test/strangertalks_new/retention_cleanup_db_test.exs`,
`mix test test/strangertalks_new/hangouts/safety_test.exs`,
`mix precommit`,
`mix hex.audit`,
`node --test test/js/*.mjs`,
and applicable browser/adversarial tests on a proven isolated environment.

Team 2B **has not run these on an integrated SHA**, performed no production test, and did not verify release-specific dependency audit. Historical resolved Bandit/Postgrex/Mint advisories must not be treated as open absent new evidence. PR #291 stays independent and unmerged until Central Command reviews exact-head CI.

## Launch verdict at this audit checkpoint

- Core 1:1 technical security: **CONDITIONAL** (not re-proven on integrated release candidate).
- Hangouts security: **NO-GO** (SEC-001 plus operational deficiencies).
- Operational trust: **NO-GO** (SEC-002/003/004 unresolved).
- Integrated global-access beta security: **NO-GO until gates closed and exact SHA verified**.

Central Command controls product decisions, branch integration, production deployment and public launch authorization.
