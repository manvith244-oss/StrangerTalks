# StrangerTalks Entrance Instrumentation Audit v1

Canonical baseline inspected: `65b6bf065193269c52cc73c5231dc64546b92d38`

Owner: Manvith

Instrumentation DRI: Partner 02

Independent reviewer: Partner 01

## Verdict

StrangerTalks already has useful backend/domain Telemetry, but it does not currently expose a trustworthy end-to-end product baseline for the entrance → intent → interaction-language → queue → match → first accepted message journey.

The missing layer is client product-event instrumentation plus explicit correlation to server-authoritative transitions.

## Existing backend authority

### Queue admission

`lib/strangertalks_new/matchmaking/queue_engine/matchmaking_engine.ex`

- canonical queue join logic lives here;
- successful joins emit `[:queue, :joined]` Telemetry;
- successful matching emits `[:match, :created]` Telemetry.

`lib/strangertalks_new_web/participant_channel.ex`

- accepts `queue:join` / `join_queue` requests;
- after successful admission it pushes/replies with `queue:status` containing `status: "queued"` and an authoritative `queue_attempt_id`.

Client product analytics must not treat the outbound `queue:join` request as successful admission. The first authoritative boundary is the server success / queued status.

### Match authority

`lib/strangertalks_new/matchmaking/queue_engine/matchmaking_engine.ex`

- successful match creation emits `[:match, :created]`.

`priv/static/assets/app.js`

- receives participant-channel queue/match state;
- existing browser tests already distinguish received `queue:status` states such as `queued` and `matched`.

Product analytics should mark match success from authoritative received state, not from client anticipation.

### First-message authority

`lib/strangertalks_new/conversation_lifecycle/conversation_server.ex`

- accepted messages emit `[:message, :accepted]`;
- delivered messages emit separate `[:message, :delivered]` Telemetry.

The product success event for "first message" must correspond to server acceptance, not textarea submission or send-button click.

## Existing operational telemetry

`lib/strangertalks_new_web/telemetry.ex` currently defines metrics for, among other things:

- queue joined / left;
- match created;
- conversation created / transitioned;
- message accepted / delivered / failed;
- queue residence duration;
- match operation duration;
- message accept / terminal duration;
- runtime health.

This is useful operational evidence.

It is not a substitute for entrance-level product events.

The inspected Telemetry supervisor contains no active reporter/exporter configuration in that module; the example reporter line is commented. A separate production metrics pipeline may exist outside this module, but no such pipeline was proven during this audit.

## Existing client flow surfaces

### Entrance and Door presentation

`priv/static/index.html`

- contains the entrance surface, Four Doors host, current language control, Hangout banner, trust cue, and temporary-conversation disclosure.

`priv/static/assets/door_mapping.mjs`

- defines the Four Door presentation aliases and queue payload mapping;
- imports the arrival and current language-placement layers.

### Entrance behavior

`priv/static/assets/arrival_first_minute.mjs`

- observes Door clicks;
- currently blocks a Door click when no conversation language exists;
- owns current language validation/help behavior;
- owns first-minute loading/failure state behavior.

This is a primary source for `st_intent_selected`, `st_talk_language_opened`, `st_talk_language_selected`, and explicit entrance cancellation/validation behavior, but instrumentation should be placed in a dedicated product-event module rather than mixing analytics transport into copy/placement logic.

### Current language placement

`priv/static/assets/interface_language_placement.mjs`

- moves the existing conversation-language control into the global header;
- this placement is transitional according to the Language Team semantic decision.

Instrumentation must not encode the header as a permanent semantic assumption.

### Matchmaking request and received state

`priv/static/assets/app.js`

- owns `startMatchingFor(doorLabel)`;
- constructs the queue payload using selected Door + interaction language;
- sends exactly one `queue:join` request in the current canonical path;
- receives `queue:status` from the participant channel;
- stores `queueAttemptId` and other conversation authority state.

This is the correct boundary for:

- `st_queue_requested` before the outbound request;
- authoritative queue admission after server-confirmed queued state;
- authoritative match correlation after received matched/match-found state.

### Loading/reconciliation guard

`priv/static/assets/flow_loading_runtime.mjs`

- wraps queue-status presentation and guards stale/duplicate queue state.

Instrumentation must respect these existing authority/reconciliation laws so reconnect or stale status does not inflate funnel counts.

## Existing tests useful for instrumentation work

- `test/js/door_click_flow_test.mjs` — proves the canonical `startMatchingFor` queue request path.
- `test/js/arrival_first_minute_browser_test.mjs` — entrance and missing-language behavior.
- `test/js/interface_language_placement_test.mjs` — current transitional placement.
- `test/js/browser_e2e_test.mjs` — authoritative websocket journey and queue/match states.
- `test/js/f01_app_shell_browser_test.mjs` — waits for authoritative `queue:status: queued` after a Door click.
- `test/strangertalks_new_web/channels/participant_channel_test.exs` — server queue-status authority.

Do not weaken these tests to accommodate analytics. Add focused tests that prove analytics is observational and cannot change product behavior.

## Missing client product-event layer

No canonical code-search evidence was found for:

- PostHog client capture;
- a generic product analytics module;
- `navigator.sendBeacon` analytics transport;
- entrance funnel custom events.

The connected PostHog project inspected during this audit has no ingested events and has not completed SDK onboarding. It cannot serve as historical StrangerTalks baseline evidence.

## Required event semantics

### `st_entrance_ready`

Meaning: the primary entrance is genuinely interactive, not merely DOM-loaded.

Required properties:

- `flow_attempt_id`
- build/release identifier if safely available
- device class
- `remembered_talk_language: true|false`

Must fire once per entrance attempt.

### `st_intent_selected`

Meaning: the human selects a primary conversation intention.

Required properties:

- `flow_attempt_id`
- intent family (`four_doors` initially)
- intent value (backend-safe or stable canonical code, not free text)
- selection kind (`first` or `change`)

Do not derive personality traits from this event.

### `st_intent_changed`

Meaning: a previously selected primary intent is replaced before successful queue admission.

Required properties:

- `flow_attempt_id`
- from intent
- to intent

### `st_talk_language_opened`

Meaning: the interaction-language chooser becomes available/opened because the person invoked it or because a missing language became necessary after intent selection.

Required properties:

- `flow_attempt_id`
- trigger: `direct` or `required_after_intent`

### `st_talk_language_selected`

Meaning: a valid interaction language is selected for the pending/next interaction.

Required properties:

- `flow_attempt_id`
- language code from the validated product contract
- source: `remembered`, `new`, or `changed`
- trigger where applicable

Language is interaction context, not a person identity property.

### `st_queue_requested`

Meaning: the client sent an attempt to begin matchmaking.

Required properties:

- `flow_attempt_id`
- intent code
- interaction-language code

This event is NOT queue admission.

### authoritative queue admission

Meaning: server confirms queue state as queued.

Required properties:

- `flow_attempt_id`
- authoritative queue attempt identifier only if privacy/data-retention review permits its use in product analytics
- intent code

If queue-attempt identifiers are retained, keep them scoped to the flow and avoid persisting them as person traits.

### authoritative match correlation

Meaning: server-authoritative match state reaches the client.

Required properties:

- `flow_attempt_id`
- intent code

Do not require storage of match IDs in the analytics layer unless a separate proof shows they are necessary.

### first accepted human message

Meaning: the first human text/message operation for the matched conversation receives server acceptance.

Required properties:

- `flow_attempt_id`
- message type only if needed for analysis

No message content.

The event must fire once for the flow.

### `st_flow_cancelled`

Meaning: the human explicitly cancels a measurable stage.

Required properties:

- `flow_attempt_id`
- stage
- bounded reason code when known from an explicit action

Never guess a psychological reason for cancellation.

## Transport design constraint

Partner 02 may select the minimal transport implementation, but it must satisfy:

1. analytics calls are non-blocking from the product’s perspective;
2. analytics exceptions/failures never prevent matchmaking or messaging;
3. event payloads are allowlisted, not arbitrary DOM/state dumps;
4. no message content, email, name, profile text, or exact location;
5. test traffic can be separated;
6. event emission can be tested without a live third-party network dependency;
7. provider-specific code is isolated behind one product-event interface so product semantics do not become PostHog-specific.

## Integrity gate

Baseline collection is forbidden until Partner 02 proves:

- entrance-ready fires once;
- first intent vs changed intent are distinguishable;
- direct vs required-after-intent language opening is distinguishable;
- queue requested is not counted as queue admitted;
- match success is server-grounded;
- first message is server-accepted;
- reconnect/duplicate paths do not inflate conversion counts;
- analytics failure leaves the user journey unchanged.

## Audit status

`COMPLETE` for current canonical-main source mapping.

Known external uncertainty: production deployment/analytics exporter configuration outside the inspected repository code was not proven by this audit.
