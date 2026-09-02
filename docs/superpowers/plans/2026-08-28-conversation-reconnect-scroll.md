# Conversation Reconnect Scroll Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Preserve an intentionally scrolled-up Conversation timeline when peer presence reconnects while retaining automatic bottom-following for users already near the newest message.

**Architecture:** Exercise the existing real Phoenix presence path in Chromium: peer WebSocket disconnect, `ConversationServer` presence transition, peer WebSocket reconnect, `conversation:presence` delivery, and the browser handler. Change only the connected-presence scroll decision so it reuses the existing `timelineNearBottom()` policy already used by incoming messages.

**Tech Stack:** Phoenix Channels, browser JavaScript, Node test runner, Playwright Chromium, GitHub Actions, PostgreSQL 16.

**Spec:** Active user instruction dated 2026-08-28, sub-step 2 — reconnect must not disturb intentional scroll position.

## Global Constraints

- Keep PR #118 open and unmerged.
- Base this sub-step directly on `release/prep-2026-08-22`; do not stack it on sub-step 1.
- Prove the real offending path and a genuine browser RED before changing `app.js`.
- Preserve the existing near-bottom auto-scroll behavior.
- Make no draft-persistence changes in this sub-step.

---

### Task 1: Real reconnect/presence browser regression

**Files:**
- Modify: `test/js/browser_e2e_test.mjs`
- Create: `.github/workflows/conversation-reconnect-scroll.yml`

**Interfaces:**
- Consumes: `matchPair(browser, "Advice", {controllableA: true})`, `disconnectSocket()`, `reconnectSocket()`, and the real `conversation:presence` Phoenix frame journal.
- Produces: a focused browser test named `peer reconnect preserves intentional timeline position and follows when near bottom`.

- [ ] **Step 1: Add timeline measurement helpers**

```js
async function timelinePosition(page) {
  return page.locator("#message-viewport").evaluate((viewport) => ({
    scrollTop: viewport.scrollTop,
    maxScrollTop: viewport.scrollHeight - viewport.clientHeight,
    bottomDistance: viewport.scrollHeight - viewport.scrollTop - viewport.clientHeight
  }))
}
```

- [ ] **Step 2: Write the failing real-browser test**

Create a real matched pair, send enough real messages to overflow `#message-viewport`, scroll participant B more than 80 px away from the bottom, reconnect participant A, and wait for B's real `conversation:presence` payload with `status === "connected"`. Assert B's `scrollTop` remains within one pixel of its intentional anchor. Then place B 40 px from the bottom, perform a second peer reconnect, and assert B reaches the exact bottom.

- [ ] **Step 3: Add focused exact-SHA CI**

Create `conversation-reconnect-scroll.yml` with PostgreSQL 16, Elixir 1.18.4 / OTP 27.3.4, Node 22, Chromium, a normal `DBConnection.ConnectionPool` browser Repo, exact checkout identity assertion, and:

```bash
node --test --test-name-pattern='peer reconnect preserves intentional timeline position and follows when near bottom' test/js/browser_e2e_test.mjs
```

- [ ] **Step 4: Run and record RED**

Push the test-only commit and require the focused workflow to fail on the intentionally-scrolled-up assertion while its actual received frame is `conversation:presence` with `status: connected`.

### Task 2: Minimal presence-scroll policy fix

**Files:**
- Modify: `priv/static/assets/app.js`
- Test: `test/js/browser_e2e_test.mjs`

**Interfaces:**
- Consumes: existing `timelineNearBottom(): boolean` and `scrollTimelineToNewest(options?): void`.
- Produces: connected peer-presence events scroll only when the timeline was already near bottom.

- [ ] **Step 1: Apply the minimal implementation**

```js
onCurrent("conversation:presence", ({status}) => {
  updatePresenceDisplay(status)
  if (status === "connected" && timelineNearBottom()) scrollTimelineToNewest()
})
```

- [ ] **Step 2: Verify focused GREEN locally**

Run the focused real-browser test against a fresh browser database and confirm both the scrolled-up anchor assertion and the 40-pixel near-bottom follow assertion pass.

- [ ] **Step 3: Run project verification**

Run `mix precommit` and inspect the complete output for zero failures.

- [ ] **Step 4: Commit, push, and verify exact-head CI**

Commit the one-line app fix separately from the RED test commit, push the branch, and require the focused workflow to pass on the exact final SHA before opening the isolated sub-step 2 PR.

