# Team 6 Product UX Re-audit Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Re-audit StrangerTalks Team 6 product UX, device behavior, accessibility, recovery/terminal presentation, safety/privacy copy, and failure presentation from audited release-prep SHA `585637924ff45933c7b35b0bc27719934907c70e`, fixing only proven Team 6-owned divergences.

**Architecture:** Preserve the current Phoenix/static-JS product and existing Instagram-inspired Conversation direction. Use the maintained Team 6 GitHub Actions gate as the executable closure harness, distinguish real browser reachability proof from synthetic presentation fixtures, inspect generated screenshots, and route backend-authority divergences to the owning team instead of compensating in frontend code.

**Tech Stack:** Elixir 1.18.4, OTP 27.3.4, Phoenix, PostgreSQL 16, Node 22, Playwright Chromium, maintained Node test suite.

**Spec:** Team 6 charter supplied for the 2026-08-26 re-audit; audited starting SHA `585637924ff45933c7b35b0bc27719934907c70e`.

## Global Constraints

- Do not work from stale `main`; start exactly from `585637924ff45933c7b35b0bc27719934907c70e`.
- Preserve valid existing redesign work and do not overwrite newer backend/authority fixes.
- Do not invent product features or rewrite the frontend framework.
- Do not change matchmaking, Door graph, Conversation Language authority, retention policy, WebRTC authority, normal-media authority, deployment, or unrelated backend code.
- The UI must never claim more authority, privacy, persistence, or recovery than the backend provides.
- Run break → fix → regression → re-attack for every proven Team 6-owned defect.
- Real browser evidence is required for layout/interaction claims; synthetic DOM fixtures are presentation evidence only.
- Final evidence must include exact tested SHA, `mix precommit`, `git diff --check`, and clean `git status --porcelain`.

---

### Task 1: Freeze the exact re-audit lane

**Files:**
- Read: `.github/workflows/team6-product-ux.yml`
- Read: `test/js/team6_real_ux_browser_test.mjs`
- Read: `test/js/team6_product_ux_browser_test.mjs`
- Read: `test/js/browser_e2e_test.mjs`
- Read: `priv/static/assets/arrival_first_minute.mjs`
- Read: `priv/static/assets/instagram_chat.mjs`
- Read: `priv/static/index.html`

**Interfaces:**
- Consumes: audited release-prep commit `585637924ff45933c7b35b0bc27719934907c70e`.
- Produces: isolated branch `team6/product-ux-reaudit-2026-08-26` whose parent is the audited SHA and whose only initial delta is this plan.

- [ ] **Step 1: Verify branch ancestry**

Run through GitHub compare/commit metadata and verify the branch parent is exactly `585637924ff45933c7b35b0bc27719934907c70e`.

- [ ] **Step 2: Inspect the maintained Team 6 gate**

Confirm the workflow checks out the event head exactly, runs focused JS regressions, starts a real Phoenix/PostgreSQL browser server, runs real Arrival/accessibility/Conversation journeys, separately labels synthetic presentation fixtures, uploads screenshots, runs full `mix precommit`, and proves a clean exact SHA.

- [ ] **Step 3: Open a draft PR to `release/prep-2026-08-22`**

The PR exists to execute the maintained Team 6 gate against the isolated branch. Keep it draft while evidence is incomplete.

### Task 2: Execute the baseline Team 6 gate before modifying product code

**Files:**
- Test: `test/js/instagram_chat_test.mjs`
- Test: `test/js/reply_quote_test.mjs`
- Test: `test/js/reaction_test.mjs`
- Test: `test/js/message_edit_test.mjs`
- Test: `test/js/message_unsend_test.mjs`
- Test: `test/js/pin_test.mjs`
- Test: `test/js/expressive_media_test.mjs`
- Test: `test/js/voice_notes_test.mjs`
- Test: `test/js/view_once_test.mjs`
- Test: `test/js/live_call_test.mjs`
- Test: `test/js/team6_media_gate_test.mjs`
- Test: `test/js/team6_media_privacy_test.mjs`
- Test: `test/js/team6_voice_note_permission_test.mjs`
- Test: `test/js/ephemeral_conversation_ux_test.mjs`
- Test: `test/js/arrival_first_minute_browser_test.mjs`
- Test: `test/js/arrival_accessibility_browser_test.mjs`
- Test: `test/js/team6_real_ux_browser_test.mjs`
- Test: `test/js/browser_e2e_test.mjs`
- Test: `test/js/instagram_chat_browser_test.mjs`
- Test: `test/js/instagram_chat_report_browser_test.mjs`
- Test: `test/js/team6_product_ux_browser_test.mjs`

**Interfaces:**
- Consumes: Team 6 workflow in `.github/workflows/team6-product-ux.yml`.
- Produces: pass/fail evidence for maintained JS, browser, responsive, accessibility, reconnect, terminal, report/privacy, media/call presentation, full precommit, clean tree, and exact SHA.

- [ ] **Step 1: Run the PR-triggered Team 6 workflow unchanged**

Expected: the workflow identifies its exact expected/head SHA before any test runs.

- [ ] **Step 2: Treat the first red step as the first divergence**

Do not patch later symptoms. Fetch the failing job log and the exact failing assertion/error, then trace from the failing user-visible state to the frontend code that produced it.

- [ ] **Step 3: Record green steps without overclaiming**

Real-browser tests prove reachability/interaction only for flows they actually exercise. `team6_product_ux_browser_test.mjs`, `instagram_chat_browser_test.mjs`, and `instagram_chat_report_browser_test.mjs` remain synthetic presentation/layout evidence where they directly install DOM state.

### Task 3: Inspect screenshot artifacts as visual evidence

**Files:**
- Generated artifact directories: `tmp/team6-real-ux-screenshots`
- Generated artifact directories: `tmp/team6-product-ux-screenshots`
- Generated artifact directories: `tmp/arrival-first-60-screenshots`
- Generated artifact directories: `tmp/chat-ui-screenshots`

**Interfaces:**
- Consumes: screenshot ZIP uploaded by the successful or partially successful Team 6 workflow.
- Produces: visual findings for overflow, clipping, hierarchy, touch sizing, dialogs, call/media controls, and obvious contradictory state presentation.

- [ ] **Step 1: Download the workflow artifact for the exact candidate SHA**

Expected artifact name prefix: `team6-product-ux-screenshots-` followed by the candidate head SHA.

- [ ] **Step 2: Inspect every generated PNG, not only file presence**

Check small mobile, modern mobile, landscape, tablet, desktop, Arrival/Queue/Conversation/tools/report/media/call fixtures represented by the artifact.

- [ ] **Step 3: Classify evidence honestly**

A screenshot created from synthetic state may prove layout but cannot prove the user can reach that state through the product.

### Task 4: Fix only a proven Team 6-owned first divergence

**Files:**
- Modify only the frontend asset/template that the failing evidence traces to, normally one of `priv/static/assets/arrival_first_minute.mjs`, `priv/static/assets/instagram_chat.mjs`, or `priv/static/index.html`.
- Test in the nearest maintained Team 6/Conversation test file that reproduces the divergence.

**Interfaces:**
- Consumes: one reproducible first divergence from Task 2 or Task 3.
- Produces: one minimal frontend fix plus one permanent regression; backend-authority defects are routed instead of patched in UI.

- [ ] **Step 1: Write the failing regression before changing product code**

Use the existing test style nearest the affected state. The regression must fail against the pre-fix branch head for the exact user-visible divergence.

- [ ] **Step 2: Run only that regression and verify RED**

Expected: the new assertion fails for the reproduced divergence, not because of setup or unrelated infrastructure.

- [ ] **Step 3: Implement the smallest frontend correction**

Preserve the current design direction. Do not bundle refactors or foreign-authority changes.

- [ ] **Step 4: Run the focused regression and verify GREEN**

Expected: the new regression and neighboring maintained tests pass.

- [ ] **Step 5: Re-run the full Team 6 workflow**

Expected: the fixed state survives the same hostile browser and unit suite that exposed it.

### Task 5: Final closure evidence

**Files:**
- Read: final workflow logs and screenshot artifact.
- No product changes after the final successful exact-SHA run.

**Interfaces:**
- Consumes: final exact candidate SHA and its completed Team 6 workflow.
- Produces: Team 6 verdict using the charter's required evidence sections.

- [ ] **Step 1: Verify `mix precommit` is green on the final SHA**

- [ ] **Step 2: Verify `git diff --check` is green on the final SHA**

- [ ] **Step 3: Verify final `git status --porcelain` is empty inside CI**

- [ ] **Step 4: Verify expected, checked-out, tested, and final SHA are identical**

- [ ] **Step 5: List every unproven charter area instead of inferring PASS**

- [ ] **Step 6: Recommend `READY FOR TEAM 11 RE-ATTACK` only if no Team 6-owned blockers remain and the required evidence is actually present**
