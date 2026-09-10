# Entrance Product-Event Instrumentation Implementation Plan

**Goal:** Build a minimal, privacy-bounded, provider-isolated product-event layer that measures the canonical 1:1 entrance → intent → interaction language → authoritative queue admission → authoritative match → first server-accepted message journey without changing product semantics.

**Owner:** Manvith

**Implementation DRI:** Partner 02 — Interface Language Architecture & Placement

**Independent reviewer:** Partner 01 — World Language & Meaning

**Issue:** #247

**Implementation branch:** `language/p02-entrance-instrumentation-2026-09-11`

**Canonical base inspected:** `65b6bf065193269c52cc73c5231dc64546b92d38`

**Source contracts:**
- `docs/product/language-team/measurement-contract-v0.3.md`
- `docs/product/language-team/instrumentation-audit-v1.md`

## Non-goals

Do not change:

- Four Door names or backend Door values;
- current matchmaking rules;
- current conversation-language contract;
- Hangout/Happening behavior;
- entrance copy or hierarchy except where a tiny hook is strictly necessary to observe existing behavior;
- retention, identity, safety, or conversation lifecycle semantics.

Do not send message content, names, emails, profile text, exact location, or derived personality labels to analytics.

Do not make analytics availability a dependency of matching or messaging.

---

## Task 1 — Add the provider-neutral event core using TDD

**Files:**
- Create: `priv/static/assets/product_events.mjs`
- Create: `test/js/product_events_test.mjs`

### RED

Write tests that import the proposed product-event module and fail because it does not exist yet.

Tests must require:

1. a fresh in-memory `flow_attempt_id` generated from an injectable UUID source;
2. an allowlist of event names;
3. an allowlist of properties per event;
4. unknown properties are rejected or dropped deterministically rather than serialized blindly;
5. an injected sink receives sanitized events;
6. sink exceptions/rejections never escape into the product call site;
7. no-op sink is valid;
8. once-only events cannot double-fire for the same flow where the contract says once;
9. test/internal traffic can be marked without person identity.

Run:

`node --test test/js/product_events_test.mjs`

Expected RED: module/import or missing-export failure.

### GREEN

Implement only enough in `product_events.mjs` to satisfy the tests.

Recommended interface shape:

- `createProductEventTracker(options)`
- `tracker.flowAttemptId`
- `tracker.capture(eventName, properties)`
- `tracker.captureOnce(eventName, properties)`
- `tracker.resetFlow()` only when a genuinely new entrance attempt begins

The sink must be injected and provider-agnostic.

The tracker must never read arbitrary DOM state or serialize the whole `app` object.

Run the focused test again and require PASS.

### REFACTOR

Keep the event/property schema centralized and readable. Do not add PostHog-specific naming or SDK calls to this file.

Commit:

`feat: add privacy-bounded product event core`

---

## Task 2 — Prove entrance-ready semantics

**Files:**
- Modify: `priv/static/assets/arrival_first_minute.mjs` or the narrowest existing boot/arrival hook that can prove interactivity
- Modify: `priv/static/assets/app.js` only if canonical bootstrap completion is the correct authority
- Create or modify: `test/js/product_events_arrival_test.mjs`

### RED

Write a test proving `st_entrance_ready` fires exactly once only after the entrance is genuinely usable, not merely after HTML parse.

Required properties:

- `flow_attempt_id`
- `remembered_talk_language`
- device class from a bounded enum (`mobile`, `tablet`, `desktop`, `unknown`)
- release/build identifier only if already safely available at runtime; otherwise omit rather than invent
- `test_traffic`

Prove repeated boot/reconciliation callbacks do not duplicate the event.

Run focused test and require failure.

### GREEN

Add the smallest integration hook to emit the event.

Analytics failure must not affect readiness.

Run focused test and require PASS.

Commit:

`feat: measure interactive entrance readiness`

---

## Task 3 — Instrument intent selection and reversal

**Files:**
- Modify: `priv/static/assets/arrival_first_minute.mjs`
- Modify only if necessary: `priv/static/assets/door_mapping.mjs`
- Create or modify: `test/js/product_events_intent_test.mjs`

### RED

Write tests proving:

1. the first Door click emits `st_intent_selected` with `selection_kind: first`;
2. a changed Door before authoritative queue admission emits `st_intent_changed` with bounded `from_intent` / `to_intent`;
3. a repeated click on the same Door does not manufacture a change;
4. Door values use stable canonical codes, not visible free-text copy;
5. no user/personality property is created.

Do not redesign the current missing-language behavior in this instrumentation slice.

### GREEN

Instrument the existing Door path without changing the current matching behavior.

Run focused test and require PASS.

Commit:

`feat: measure entrance intent selection`

---

## Task 4 — Instrument interaction-language behavior

**Files:**
- Modify: `priv/static/assets/interface_language_placement.mjs`
- Modify: `priv/static/assets/arrival_first_minute.mjs`
- Modify only if necessary: `priv/static/assets/f11_persistence_runtime.mjs`
- Create or modify: `test/js/product_events_language_test.mjs`

### RED

Write tests proving:

1. opening/invoking the existing language control emits `st_talk_language_opened` with trigger `direct` where observable;
2. current missing-language-after-Door behavior can be classified as `required_after_intent` without altering the UI yet;
3. valid selection emits `st_talk_language_selected` with only validated language code plus bounded source (`remembered`, `new`, `changed`);
4. an existing remembered valid language is marked as remembered context, not as a user identity;
5. invalid/free-form values are never emitted.

The current header placement remains transitional but is not changed in this instrumentation task.

### GREEN

Add observational hooks only.

Commit:

`feat: measure interaction language context`

---

## Task 5 — Separate queue request from authoritative queue admission

**Files:**
- Modify: `priv/static/assets/app.js`
- Create or modify: `test/js/product_events_queue_test.mjs`
- Preserve: `test/js/door_click_flow_test.mjs`
- Preserve: `test/js/browser_e2e_test.mjs`

### RED

Write tests proving:

1. `st_queue_requested` fires immediately before the canonical outbound `queue:join` request;
2. the event carries bounded intent + interaction-language context and current `flow_attempt_id`;
3. request failure does NOT emit authoritative queue admission;
4. received `queue:status` with `status: queued` emits the authoritative admission event once;
5. reconnect/replayed duplicate queued status for the same queue attempt does not inflate admission count;
6. stale queue attempt IDs are ignored according to existing authority rules.

### GREEN

Integrate with `startMatchingFor(doorLabel)` and the existing participant `queue:status` handler.

Do not count screen transition to `queue` as server admission.

Run focused test plus:

`node --test test/js/door_click_flow_test.mjs`

Commit:

`feat: correlate queue request with authoritative admission`

---

## Task 6 — Instrument authoritative match

**Files:**
- Modify: `priv/static/assets/app.js`
- Modify only if authority wrapper requires it: `priv/static/assets/flow_loading_runtime.mjs`
- Create or modify: `test/js/product_events_match_test.mjs`
- Preserve: `test/js/browser_e2e_test.mjs`

### RED

Write tests proving:

1. client expectation or queue display never emits match success;
2. canonical received `match_found` / authoritative matched transition emits `st_match_created` exactly once per flow;
3. duplicate/recovered match notifications do not inflate the funnel;
4. no match ID is sent to analytics unless a separate proof demonstrates necessity (default: omit it).

### GREEN

Add the smallest authority-grounded hook.

Run focused test and the existing browser E2E path.

Commit:

`feat: measure authoritative match creation`

---

## Task 7 — Instrument first server-accepted human message

**Files:**
- Modify: `priv/static/assets/app.js`
- Create or modify: `test/js/product_events_first_message_test.mjs`
- Preserve relevant reliability tests around `message:send`

### RED

Write tests proving:

1. submit/button click alone does not emit success;
2. rejected/timeout send does not emit success;
3. the first successful server reply to canonical `message:send` emits `st_first_message_accepted` once;
4. later accepted messages do not emit another first-message event for the same flow;
5. no message body, reply content, sticker/GIF text, or message ID is included;
6. the event survives retry logic without double counting.

### GREEN

Hook only after the existing `await push(app.conversation, "message:send", sendPayload)` succeeds.

Do not alter message retry or delivery semantics.

Commit:

`feat: measure first accepted human message`

---

## Task 8 — Instrument explicit cancellations

**Files:**
- Modify the smallest current handlers for explicit cancellation/leave actions
- Create or modify: `test/js/product_events_cancel_test.mjs`

### RED

Prove `st_flow_cancelled` fires only for explicit measurable user cancellation, with bounded stage/reason codes.

Do not infer abandonment reason from inactivity.

### GREEN

Add only explicit cancel/leave hooks needed for current funnel attribution.

Commit:

`feat: measure explicit entrance flow cancellation`

---

## Task 9 — Add provider adapter behind the product-event interface

**Gate:** Do not start this task until analytics destination privacy settings are approved.

Current PostHog project audit found:

- no ingested events;
- SDK onboarding incomplete;
- session recording disabled;
- IP anonymization currently disabled.

Therefore current PostHog configuration is not yet accepted as production destination for StrangerTalks entrance analytics.

**Files (if PostHog is approved):**
- Create: `priv/static/assets/product_event_transport_posthog.mjs`
- Create: `test/js/product_event_transport_posthog_test.mjs`
- Modify runtime boot only to install the adapter

### RED

Test that the adapter:

- sends only events produced by the allowlisted core;
- does not enable session recording;
- does not enable broad autocapture;
- does not identify a persistent social/person profile for entrance measurement;
- treats network failure as non-fatal;
- can be replaced with a fake sink in tests;
- exposes a `test_traffic` property/route for filtering.

### GREEN

Implement the minimum adapter only after privacy configuration is approved.

Commit:

`feat: add approved product analytics transport`

---

## Task 10 — Integrity gate and exact-head proof

**Files:**
- Add: `docs/product/language-team/event-integrity-report-v1.md`
- Update focused tests only as required by proven behavior

Run maintained non-browser JS tests using the same classification logic as `.github/workflows/arrival-first-60.yml`.

Prepare database and run the relevant browser tests, including at minimum:

- `test/js/arrival_first_minute_browser_test.mjs`
- `test/js/arrival_accessibility_browser_test.mjs`
- `test/js/browser_e2e_test.mjs`
- `test/js/f01_app_shell_browser_test.mjs`

Then run:

`mix precommit`

and:

`git diff --check`

The integrity report must contain one row per event:

- event name;
- exact trigger;
- allowed properties;
- authoritative boundary;
- duplicate/idempotency rule;
- focused test proving it;
- known limitation;
- PASS/FAIL.

Partner 01 independently reviews the report against the measurement contract and audit.

Do not start baseline collection until every required authority/integrity case passes.

Final implementation status may only be:

- `COMPLETE`
- `MISSED`
- `BLOCKED`

with evidence attached to issue #247.
