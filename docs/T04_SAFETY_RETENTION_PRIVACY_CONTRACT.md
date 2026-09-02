# T04 Safety Evidence Retention + Privacy Contract

Packet: `T04-PRIV-001`

This document records current StrangerTalks engineering/product retention truth for T04-owned safety evidence and privacy boundaries.

It does **not** establish legal compliance and must not be described as a DPDP or other legal-compliance claim.

`StrangertalksNew.RetentionPolicy`, `StrangertalksNew.RetentionCleanup`, current schemas, runtime authority, and executable tests outrank older prose when they conflict.

This document supersedes retention-lifetime statements in `docs/TEAM4_PRIVACY_STORAGE_MAP.md` where that older map says a current safety class has "no app-level TTL found" but current `RetentionPolicy` / `RetentionCleanup` now defines bounded minimization or deletion.

## Core privacy truth

- Ordinary live Conversation text is not durably retained server-side as general Conversation history.
- Safety evidence is a separate, purpose-bounded authority. A Report may preserve authorized evidence without converting the surrounding Conversation into a durable transcript.
- Safety cleanup is not one global deletion timer. Different safety data classes have different minimization, deletion, and authority-preservation rules.
- Active safety authority must survive privacy minimization when the authority is still required.
- Local participant retention choices such as Fade do not silently erase server-side safety authority.
- Unsend removes participant-visible message content but does not retroactively destroy evidence already admitted to an authorized safety path.
- Privacy-sensitive content must remain out of ordinary telemetry and diagnostics.

## Current T04 safety data map

| Data class | Authority | Why retained | Rich data | Current minimization / deletion truth |
|---|---|---|---|---|
| Report | PostgreSQL `reports` + Reports domain | Durable report/safety authority | `reporter_context`, `reported_message_id` and report metadata | Final/resolved rich evidence is minimized at 90 days. Open/under-review rich evidence has a 180-day maximum. Current cleanup minimizes rich evidence; it does not claim the entire Report row is deleted at one fixed deadline. |
| Report safety media | PostgreSQL `report_safety_media` | Deliberately admitted safety evidence | Safety media bytes/metadata | Default cleanup at 30 days. An authoritative human review in `IN_REVIEW` may extend retention, but the absolute hard maximum is 60 days. |
| SafetyReview | PostgreSQL `safety_reviews` | Review authority tied to a Report | `review_notes`, resolution metadata | Rich notes on resolved/dismissed reviews are minimized at 90 days. The review row itself is not represented as universally deleted at that cutoff. |
| SafetyEvent | PostgreSQL `safety_events` | Private accountability / safety action history | `report_description`, `safety_summary`, sensitive-data flag | At 180 days, resolved/dismissed rich narrative is minimized. Spent old events with no continuing action/block authority may be removed. Continuing action authority is preserved while rich narrative is minimized. |
| BoundaryBlock | PostgreSQL `boundary_blocks` | Durable safety veto | Pair, active status, timestamps/source | Active Block authority is never eligible for inactive-block cleanup. Inactive history is eligible at 30 days unless an OPEN/UNDER_REVIEW SafetyEvent still requires it. |
| Ordinary live text | ConversationServer runtime + participant local state | Live communication | Message content | Zero durable server-history seconds in the current V1 policy. Active server delivery/replay state is bounded; participant local retention is separate. |
| Unsent safety snapshot | Bounded ConversationServer safety snapshot, optionally promoted into an authorized Report | Preserve exact targeted evidence across legitimate report/Unsend ordering | Exact current-canonical targeted message snapshot only | The transient snapshot is bounded. If legitimately captured into a Report before it disappears, the resulting Report evidence follows Report retention rules. Stale browser text cannot recreate absent safety authority. |

## Exact current V1 safety-retention periods

These values come from current engineering/product authority. They are not legal-advice values.

- ordinary live Conversation durable server persistence: `0` seconds
- safety media default lifetime: `30 days`
- safety media active-human-review hard maximum: `60 days`
- final/resolved Report rich evidence: `90 days`
- open/under-review Report rich evidence maximum: `180 days`
- resolved/dismissed SafetyReview rich notes: `90 days`
- SafetyEvent rich narrative: `180 days`
- inactive BoundaryBlock history: `30 days`

Do not change these periods silently. A product-policy contradiction must return through Construction Command / owner authority.

## Unsend contract

Unsend and safety evidence are intentionally different authorities.

1. If a specific message is legitimately captured into a Report before Unsend, later Unsend does not erase that already-authorized evidence.
2. If Unsend happens first while the bounded canonical safety snapshot still exists, a Report may consume that exact current-canonical targeted snapshot.
3. The safety path does not copy unrelated surrounding Conversation history merely because one message is reported or unsent.
4. Once the bounded safety snapshot is absent, stale browser-provided text cannot be promoted into durable targeted report evidence.
5. Sender-visible Unsend behavior must not reveal whether the message was reported.

## Fade contract

Fade is a participant-local retention choice.

- Fade removes the local Conversation transcript and associated local summary under the current IndexedDB retention model.
- Fade does not delete Report authority, SafetyReview authority, active BoundaryBlocks, or already-authorized server-side safety evidence.
- Server safety systems must not use Fade as justification to retain unrelated local/social content.

## Report contract

Do **not** simplify current behavior to either of these statements:

- "Reports have no automatic cleanup."
- "Reports are deleted after X days."

Both can be misleading.

Current truth is that the durable Report authority and its rich evidence have different lifetimes. Rich evidence is minimized at the applicable 90-day or 180-day boundary, while the Report row may remain as bounded safety authority.

## SafetyReview contract

Resolved/dismissed rich review notes are bounded to 90 days under current V1 cleanup. Active review state remains distinct from resolved/dismissed minimization.

## Safety media contract

Safety media is not immortal merely because a review is active.

- normal default cleanup: 30 days
- authoritative `IN_REVIEW` exception: may survive past 30 days
- absolute hard maximum: 60 days

Pending, resolved, dismissed, missing, or otherwise non-authoritative review state does not grant an unlimited extension.

## SafetyEvent contract

At the 180-day boundary, rich narrative can be minimized without erasing still-required private accountability.

A continuing action such as a match restriction can survive while `report_description`, `safety_summary`, and the sensitive-data marker are minimized.

Old resolved/dismissed events with no continuing action and no active related safety authority may be removed according to current cleanup logic.

## BoundaryBlock contract

An active Block is safety authority, not historical clutter.

Current inactive-history cleanup is restricted to inactive blocks at the 30-day boundary and protects inactive history when an OPEN/UNDER_REVIEW SafetyEvent still requires it.

Active blocks must not be deleted by retention cleanup.

## Telemetry / logging contract

Ordinary telemetry must remain content-blind.

Current sanitizer/diagnostic proofs cover removal or redaction of message content, participant/conversation/message identifiers, report evidence, credentials/tokens/cookies, and arbitrary noncanonical string values. Crash diagnostics retain bounded failure information rather than private socket/product payloads.

Logs are production data; this contract does not authorize private Conversation or safety evidence to enter generic logs.

## Stale downstream privacy claims

The following current paths contain or test the superseded meaning that stored Report / SafetyReview records have no automatic expiry or cleanup:

- `priv/static/assets/app.js`
- `test/js/message_unsend_test.mjs`
- `test/js/ephemeral_conversation_ux_test.mjs`

`docs/TEAM4_PRIVACY_STORAGE_MAP.md` also contains historical `No app-level TTL found` statements for safety classes now governed by centralized retention policy/cleanup. This document supersedes those lifetime statements; the broader storage-map observations remain useful where they do not conflict with current code.

T04 does not silently rewrite T03-owned presentation. Construction Command should route the UI/test copy correction to T03.

## Correct downstream privacy truth for T03

T03 should communicate the following meaning without promising more than the implementation proves:

> Ordinary live Conversation content is not kept as permanent server history. If you report something, StrangerTalks may keep limited safety evidence separately. That sensitive evidence is minimized or deleted on its own safety-retention schedule and does not disappear merely because a participant uses Unsend or Fade.

T03 must not claim:

- all Reports vanish after one fixed period;
- Report and SafetyReview data has no cleanup at all;
- Fade erases safety evidence;
- Unsend retroactively erases already-authorized safety evidence;
- ordinary live Conversation transcript is permanently stored;
- current engineering retention periods are a legal-compliance guarantee.

## T06 operational dependency

The approved application entry point is:

`mix strangertalks.retention`

Repository inspection currently proves the cleanup implementation and operator Mix task, but does not by itself prove that production scheduling/cron invokes it successfully.

Construction Command should route operational scheduling, failure visibility, and production execution proof to T06.

## Proof inventory

Primary executable proof includes:

- `test/strangertalks_new/team4_retention_privacy_closure_test.exs`
- `test/strangertalks_new/retention_policy_test.exs`
- `test/strangertalks_new/retention_cleanup_test.exs`
- `test/strangertalks_new/retention_cleanup_db_test.exs`
- `test/strangertalks_new/retention_safety_media_closure_test.exs`
- `test/strangertalks_new/retention_closure_db_test.exs`
- `test/strangertalks_new/privacy_persistence_guard_test.exs`
- `test/strangertalks_new/conversation_unsend_report_safety_test.exs`
- `test/strangertalks_new/conversation_message_unsend_test.exs`
- `test/strangertalks_new/telemetry_privacy_test.exs`
- `test/strangertalks_new_web/channel_crash_diagnostic_privacy_test.exs`
- `test/strangertalks_new_web/expressive_diagnostic_privacy_test.exs`
- `test/strangertalks_new_web/safety_media_access_privacy_test.exs`
- `test/js/local_data_test.mjs`
- existing browser privacy/copy tests used to identify stale downstream wording

## Routing boundary

T04 defines and proves this safety/privacy truth.

- T03 owns final browser copy/presentation changes.
- T06 owns production scheduling/operational execution.
- T09 owns independent break/QA verification.
- T01 is required only if future proof exposes a durable schema/domain deficiency; this closure does not invent one.
