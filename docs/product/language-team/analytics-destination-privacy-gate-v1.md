# StrangerTalks Language Team — Analytics Destination Privacy Gate v1

Owner: Manvith  
Implementation DRI: Partner 02 — Interface Language Architecture & Placement  
Independent privacy/proof reviewer: Partner 01 — World Language & Meaning  
Governing issue: #247

## Purpose

No provider adapter may transmit real StrangerTalks entrance product events to a live third-party analytics destination until this gate is explicitly satisfied.

This gate is deliberately separate from the provider-neutral product-event implementation. Tasks 1–8 may proceed against fake/no-op sinks while live ingestion remains forbidden.

## Current inspected destination

Connected analytics project inspected on 2026-09-11:

- provider: PostHog;
- project ID: `578439`;
- project name: `Default project`;
- `ingested_event: false`;
- snippet onboarding incomplete;
- IP anonymization disabled (`anonymize_ips: false`);
- session recording disabled (`session_recording_opt_in: false`);
- project-level console-log capture enabled (`capture_console_log_opt_in: true`);
- project-level performance capture enabled (`capture_performance_opt_in: true`);
- autocapture is not proven disabled (`autocapture_opt_out` was unset/null in the inspected project settings);
- person-on-events querying is enabled;
- event retention is configured as 12 months, with enforcement not proven enabled in the inspected settings.

A fresh event-schema inspection on 2026-09-11 showed no events seen in the last 30 days. Provider reference event names may still appear in schema discovery and must not be mistaken for collected StrangerTalks traffic.

Credentials, project tokens, and ingestion keys must never be copied into this document, issue comments, tests, screenshots, or source control.

## Current verdict

# NOT APPROVED FOR PRODUCTION INGESTION

Reason:

1. IP handling is not privacy-ready under the inspected configuration because IP anonymization is disabled.
2. Broad collection surfaces are not yet explicitly locked down for the narrow StrangerTalks measurement purpose.
3. No controlled synthetic ingestion proof exists showing the actual final event/property shape received by the destination.
4. Retention and data-residency choices have not yet been accepted as part of this workstream.

This verdict does **not** block the provider-neutral product-event core or Tasks 1–8 of the implementation plan.

## Required approval conditions

All conditions below must be proven before production ingestion.

### 1. Explicit-event-only integration

StrangerTalks entrance analytics must use the explicit custom-event allowlist defined by the product-event core.

Do not rely on DOM autocapture for this workstream.

The approved transport must not serialize arbitrary DOM elements, visible text, form values, application state, or websocket payloads.

### 2. Session recording disabled

Session recording must remain disabled for this measurement layer.

Any future proposal to use replay requires a separate privacy/safety review and is outside issue #247.

### 3. Autocapture disabled or technically excluded

The final integration must prove that broad autocapture cannot collect StrangerTalks interaction text or surrounding DOM state.

An unset provider default is not proof.

### 4. Console-log collection disabled for this measurement layer

The integration must not forward arbitrary browser console contents as part of entrance analytics.

If another engineering workstream needs console capture, it must be independently scoped and reviewed rather than inherited silently by this product-measurement adapter.

### 5. Performance collection separately justified

Entrance product measurement does not require broad performance capture by default.

If performance telemetry is retained, the exact fields, purpose, and privacy effect require a separate documented approval.

### 6. IP protection

Before production traffic is accepted, enable provider-supported IP anonymization or prove an equivalent reviewed control that prevents raw client IP from being retained or used outside the approved scope.

Do not infer that an SDK option alone solves upstream network logging; the final deployment path must be reviewed end-to-end.

### 7. No persistent social identity

The entrance measurement layer must not call a persistent identify/person-profile API merely to build the funnel.

`flow_attempt_id` is ephemeral correlation context for one journey. It is not a public identity, relationship identifier, account identity, or personality profile.

### 8. Forbidden payload classes

The following are forbidden in entrance analytics payloads:

- message body or draft text;
- voice/audio/media content;
- names;
- email addresses;
- profile text;
- account/session secrets;
- authentication tokens;
- exact location;
- arbitrary URLs containing sensitive parameters;
- message IDs unless separately proven necessary and approved;
- match IDs unless separately proven necessary and approved;
- free-form report/reason text;
- psychological inference;
- personality labels derived from Door choice;
- persistent cross-conversation relationship inference.

### 9. Geographic data bounded

If the provider or network layer derives geographic properties automatically, the actual ingested property set must be inspected before production approval.

Only an explicitly approved coarse level may remain. Exact coordinates or equivalent fine-grained location are forbidden.

### 10. Test traffic separable

Synthetic, CI, staff, and controlled-verification traffic must be distinguishable from production baseline traffic without attaching personal identity.

The baseline query must be able to exclude test traffic deterministically.

### 11. Retention frozen before launch

The event-retention period used for this workstream must be intentionally chosen and documented before production ingestion.

A provider default is not itself an Owner-approved retention policy.

### 12. Data residency documented

The destination region/data-residency choice must be documented and accepted before production ingestion.

Do not guess residency from an endpoint or account URL.

### 13. Failure isolation

Analytics unavailability, timeout, SDK exception, blocked network request, or malformed provider response must never prevent:

- entrance rendering;
- Door selection;
- queueing;
- matching;
- conversation opening;
- message sending;
- safe cancellation/ending.

### 14. Provider adapter tested behind the semantic core

The provider adapter must receive only already-sanitized events from the provider-neutral event core.

Focused tests must prove:

- no extra properties are introduced;
- no implicit identify call is needed;
- no session recording is enabled;
- no broad autocapture is enabled;
- transport failure is non-fatal;
- test traffic remains filterable.

### 15. Controlled ingestion proof before production

After destination settings are approved, send only synthetic/test-traffic verification events first.

Then inspect the destination's **actual received event schema and properties**.

Production approval requires proof that:

- expected events arrived;
- only approved properties arrived;
- forbidden properties did not arrive;
- provider/system-added properties were reviewed;
- test events can be filtered;
- no unexpected identity/person profile was created for the measurement purpose.

## Three-phase approval procedure

### PHASE A — CODE ONLY

Status: allowed now.

Tasks 1–8 may run with fake/no-op/in-memory sinks.

No live third-party ingestion required.

### PHASE B — CONTROLLED TEST INGESTION

Requires:

- destination privacy configuration review;
- explicit approval to use the destination for synthetic events;
- test traffic only;
- post-ingestion schema/property inspection.

Passing Phase B does not automatically authorize production traffic.

### PHASE C — PRODUCTION INGESTION

Requires:

- every required condition above proven;
- event-integrity gate passed;
- Partner 01 evidence review;
- Owner acceptance of the live destination/privacy configuration.

Only then may Task 9 become production-enabled.

## Evidence packet required for approval

The approval packet must contain:

1. fresh destination settings snapshot with secrets redacted;
2. proof of IP protection;
3. proof session recording is disabled;
4. proof autocapture is disabled/excluded;
5. proof console/performance behavior is intentionally configured;
6. documented retention decision;
7. documented data-residency decision;
8. adapter test output;
9. controlled synthetic ingestion event names;
10. actual ingested property list per verification event;
11. negative proof that forbidden properties are absent;
12. proof test traffic is filterable;
13. reviewer verdict.

## Reviewer verdict vocabulary

For destination approval use only:

- `NOT APPROVED`
- `APPROVED FOR CONTROLLED TEST INGESTION`
- `APPROVED FOR PRODUCTION INGESTION`

Do not use `COMPLETE` as a substitute for destination approval.

## Present status

`NOT APPROVED`

Provider-neutral implementation may proceed.

Live StrangerTalks analytics ingestion may not proceed under issue #247 until this gate is satisfied.
