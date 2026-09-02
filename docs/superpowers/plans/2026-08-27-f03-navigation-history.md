# F-03 Navigation / History Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Apply the frozen F-02 route contract as coherent browser history without coupling route changes to Matchmaking, Conversation, terminal, safety, media, or shell lifecycle authority.

**Architecture:** Keep `route_contract.mjs` and `route_runtime.mjs` as the only route-truth layer. Add one pure F-03 history coordinator that owns push/replace/popstate, navigation revision, active-primary derivation, and deep-link parent seeding. Adapt `app.js` through a minimal route-presentation boundary so canonical activity can update while the visible route remains independent.

**Tech Stack:** Browser History API, ES modules, Node 22 test runner, Playwright/Chromium, Phoenix/Elixir integration tests.

**Spec:** F-CMD F-03 Wave-A Implementation Release — Navigation / History Authority, released 2026-08-27 from exact F-02 SHA `208185a7ed0c31c3a5c40502418be41bf8b975cb`.

## Global Constraints

- Start exactly from `208185a7ed0c31c3a5c40502418be41bf8b975cb`.
- Consume `priv/static/assets/route_contract.mjs` and `priv/static/assets/route_runtime.mjs`; do not create another router.
- Activity and route are orthogonal.
- Browser Back/Forward never emits `queue:leave`, `conversation:end`, `conversation:block`, or report actions.
- Match-found uses `/conversation` with no durable Match-found route/history stop.
- Terminalization replaces `/conversation` with `/conversation/ended` when the visible route is Conversation.
- Do not redesign shell visibility, Matchmaking lifecycle, Conversation lifecycle, persistence, terminal truth, Voice/Video, media, safety, loading UX, or recovery UX.
- One F-03 branch and one draft PR; do not merge.

---

### Task 1: Pure Navigation/History Contract

**Files:**
- Create: `test/js/navigation_history_test.mjs`
- Create: `priv/static/assets/navigation_history.mjs`

**Interfaces:**
- Consumes: `parseRoute`, `createRouteRuntimeState`, `refreshResolution`, `resolveRuntimeActivityEvent` from frozen F-02.
- Produces: `createNavigationHistory`, `primaryDestinationForPath`, `deepLinkParentPath`, `createNavigationRevision`, and `NAVIGATION_STATE_KEY`.

- [ ] **Step 1: Write the failing unit contract** covering F03-J01 through F03-J15 where the behavior can be proven without DOM/runtime channels, including push/replace classification, direct-child parent seeding, rapid stale-completion rejection, terminal/unavailable correction, and destructive-action source scanning.
- [ ] **Step 2: Run** `node --test test/js/navigation_history_test.mjs` and verify RED because the F-03 runtime is absent.
- [ ] **Step 3: Implement the minimum pure coordinator**. It must request canonical snapshots only for activity-owned routes, use one monotonic navigation revision, reject late completions, and never own DOM or channel lifecycle.
- [ ] **Step 4: Run** `node --test test/js/navigation_history_test.mjs` and verify GREEN.
- [ ] **Step 5: Run** `node --test test/js/route_contract_test.mjs test/js/navigation_history_test.mjs` and verify F-02 remains green.

### Task 2: Route Presentation Boundary in app.js

**Files:**
- Modify: `priv/static/assets/app.js`
- Test: `test/js/navigation_history_browser_test.mjs`

**Interfaces:**
- Consumes: `createNavigationHistory`, `primaryDestinationForPath`, and F-02 `routeNavigationPathForScreen`.
- Produces: one app-level navigation adapter, one popstate handler, and one route presentation function that does not perform unrelated feature lifecycle cleanup.

- [ ] **Step 1: Write browser tests** for primary/secondary navigation, Back/Forward ordering, refresh initialization, direct-entry child fallback, and active-primary derivation.
- [ ] **Step 2: Run the browser test against the old app behavior** and verify RED because URLs/history are not yet applied.
- [ ] **Step 3: Split legacy `show(name)`** so the F-03 route presentation path only applies the resolved screen and route-linked rendering; keep legacy feature cleanup outside F-03 navigation.
- [ ] **Step 4: Route `[data-go]`, saved-chat open, retention destinations, and explicit queue-entry navigation through F-03 `navigate()`/`replace()` without changing the owning feature semantics.
- [ ] **Step 5: Install exactly one `popstate` path** that resolves the browser location through F-02 and emits no destructive action.
- [ ] **Step 6: Run the focused browser test** and verify GREEN.

### Task 3: Activity ≠ Route and Canonical Event Integration

**Files:**
- Modify: `priv/static/assets/app.js`
- Test: `test/js/navigation_history_browser_test.mjs`

**Interfaces:**
- Consumes: app Participant/Conversation snapshots and F-03 route application.
- Produces: route-preserving reconciliation for QUEUED and ACTIVE_CONVERSATION, plus F-02-owned canonical activity-event route corrections.

- [ ] **Step 1: Add failing browser cases** for QUEUED + `/you`, QUEUED Back/Forward, ACTIVE Conversation + permitted navigation away, and late reconciliation after newer navigation.
- [ ] **Step 2: Run and verify RED** because current reconciliation still calls legacy `show()` paths.
- [ ] **Step 3: Update reconciliation** so activity state/runtime can refresh underneath a non-activity route; only F-02 route decisions may correct the visible location.
- [ ] **Step 4: Apply `match_found`, `conversation_ended`, and `conversation_unavailable` through F-02 activity-event decisions using REPLACE where directed.
- [ ] **Step 5: Run and verify GREEN**, including no `queue:leave` or `conversation:end` from Back/Forward.

### Task 4: Hostile Browser Proof

**Files:**
- Modify/Create: `.github/workflows/f03-navigation-history.yml`
- Test: `test/js/navigation_history_browser_test.mjs`

**Interfaces:**
- Consumes: exact F-03 head.
- Produces: exact-head CI proof for unit, browser, route-contract, precommit, diff integrity, and clean checkout.

- [ ] **Step 1: Add rapid Talk → You → Chats → Talk → Back → Forward → Back attack** and repeat while QUEUED and while an active Conversation exists.
- [ ] **Step 2: Add stale async route-validation attack** where A and B finish after newer C and prove C stays visible.
- [ ] **Step 3: Add terminal stale-history attack** proving `/conversation/ended` cannot become ACTIVE through Back/Forward.
- [ ] **Step 4: Run focused unit/browser tests, F-02 route tests, and `mix precommit`** on the exact head in CI.
- [ ] **Step 5: Run `git diff --check`, verify clean tree, and record `git rev-parse HEAD`** in CI.

### Task 5: F-CMD Evidence Return

**Files:**
- No production changes.

**Interfaces:**
- Consumes: exact final SHA, PR metadata, CI status/logs, changed-file list.
- Produces: F-03 exact-SHA verdict request.

- [ ] **Step 1: Verify PR is still draft and unmerged.**
- [ ] **Step 2: Fetch exact-head CI and require all F-03 gate steps green; queued or partial green is not accepted.**
- [ ] **Step 3: Return branch, exact starting SHA, exact final SHA, draft PR, files changed, contracts, J01–J15 evidence, full precommit, exact-head CI, blockers, and request `F-03 EXACT-SHA VERDICT`.**
