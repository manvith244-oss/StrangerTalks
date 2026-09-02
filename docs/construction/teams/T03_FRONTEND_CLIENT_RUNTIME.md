# T03 — Frontend & Client Runtime Authority

## Evolution Clause

The client stack may evolve from current JavaScript modules toward TypeScript, a framework, native clients or multiple frontends. Migration must preserve server authority, privacy, accessibility and current user-state contracts.

## Mission

Make the browser/client a truthful, resilient representation of StrangerTalks authority while delivering fast, understandable interaction across phone, tablet and desktop.

## Owned authority

- browser JavaScript runtime and possible future TypeScript migration;
- route/history presentation coordination;
- IndexedDB/local-device state;
- composer/draft/client presentation state;
- responsive client behavior;
- stale async callback guards;
- client-side recovery and optimistic-state reconciliation;
- frontend API/channel adapters.

## Preserve

- client cannot invent durable Match/Conversation/Bond authority;
- ordinary navigation cannot silently End/Cancel/Block;
- terminal state is server/durable-authority driven;
- identity/safety rules remain T04 owned;
- UX meaning/accessibility standards coordinate with T10.

## Immediate archaeology inputs

Inspect prep/integration and specialist branches touching:

- `app.js`;
- route contract/runtime;
- navigation history;
- session reconciliation;
- conversation draft persistence;
- failed-message retry;
- loading transitions;
- mobile/desktop flow;
- settings risk gradient;
- expression/runtime continuity;
- terminal client handling;
- browser E2E suites.

## Current technical posture

- JavaScript browser modules: ACTIVE NOW.
- IndexedDB/local device state: ACTIVE NOW.
- TypeScript: EVALUATE; likely useful when module contracts become harder to reason about, but avoid rewrite-for-rewrite's-sake.
- React/Next/Vue/Angular: NOT JUSTIFIED as a wholesale rewrite without measurable maintainability/product benefit.
- responsive web: ACTIVE NOW.
- native Android/iOS: trigger-based future.

## Required invariants

- current Conversation identity scopes every async operation that can mutate its UI;
- refresh/rejoin restores only valid local state;
- failed optimistic operations become truthful and recoverable;
- local drafts do not duplicate failed message bubbles;
- local persistence corruption fails safely;
- multi-tab/device behavior does not present impossible authority;
- keyboard, focus, reduced-motion and responsive behavior remain usable.

## Evidence

Use Node/module tests for pure logic, real Chromium for DOM/browser behavior, isolated browser contexts for multi-participant flows, and real-device testing when claiming device-specific behavior.

## Stop conditions

Stop if a frontend fix would require changing backend lifecycle truth, Matchmaking semantics, privacy policy, Bond meaning or another team's server protocol without coordination.
