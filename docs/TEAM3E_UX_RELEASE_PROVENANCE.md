# Team 3E — UX candidate provenance and verification log

Status: **PARTIAL / NOT RELEASE-CERTIFIED**. All tests and actual 200%/400% browser zoom must be re-run on the final exact SHA before promoting. This is a review manifest, not a claim of completion.

## Starting points

- Canonical base: `c7e750b4bd0fbf5f92ff1a0cabc728ce08d4fe66` (PR #295, merged).
- Inherited Team 3D: `ee7c6a59c2c925632905d150d5ab2bfdcc5715da` (draft PR #301, not merged).
- Prior failing real-browser workflow: https://github.com/manvith244-oss/StrangerTalks/actions/runs/37786929153
- Observed on inherited SHA: mandatory two-participant tests **3/3 pass**; arrival/accessibility **2/9 pass, 7/9 fail**. Later stages skipped.

## Provenance and scope

- `config/test.exs`: carry over Team 3D *loopback-only* Phoenix WebSocket origin allowlist; bounded synthetic participant issuance in the **persistent test-server process only**. Production admission and default Elixir test policies remain unchanged.
- `.github/workflows/team3c-real-browser-ux.yml`: inherited exact-SHA real Phoenix/PostgreSQL 17/Chromium harness, Team 3E branch enabled. No staging/production dependencies.
- `priv/static/assets/app.js`: narrowly port Team 3D's Report safety-dropdown closing and focus restoration.
- `priv/static/assets/instagram_chat.css`: preserve mainline responsive CSS from merged #295; port **only** the final Team 3D compact Voice Privacy block, not the older CSS body.
- `test/js/team6_real_ux_browser_test.mjs`: preserve inherited passing three-test suite and session diagnostics.
- `priv/static/assets/flow_loading_runtime.mjs`: give keyboard focus to the actual `#boot-bridge` recovery button when session authority fails, not to any Door.
- `test/js/arrival_first_minute_browser_test.mjs`: align synthetic initial 503 verification with authoritative boot bridge and verify reloading after clearing failure.
- `test/js/arrival_accessibility_browser_test.mjs`: add status-only admission/socket diagnostics and layout hit-test geometry without logging tokens, cookies, transcripts, or content; preserve normal Playwright click with no force.

## Root-cause hypotheses to validate

1. Production issuance policy in `ParticipantIssuance` is source-scoped: 6/60s, 12/15min, 20/60min. CI runs many independent synthetic participants through one loopback IP and persistent database. Seven later browser failures are **consistent** with quota exhaustion. Confirm actual response status in the new CI logs before labeling ROOT CAUSE. The test-only policy is still bounded, not disabled.
2. New F07 bootstrap gates Arrival behind `body.flow-booting` and uses the `#boot-bridge` reload control, whereas the older test asserted legacy `#arrival-startup-failure`. Verify error state, focus, and recovery under injected 503.
3. `Emulation.setPageScaleFactor(2)` emulates page/pinch scale, **not** actual desktop 200% zoom. Existing click interception is real for that test environment. Newly captured target/banner/heading/visualViewport geometry must establish whether the source is layout overlap or coordinate emulation. Do not remove the assertion or force click.

## Gates required before UX acceptance

- New candidate exact-SHA CI fully green: mandatory 3/3; arrival/accessibility 9/9; terminal/reconnect; full JavaScript; focused Phoenix; `mix precommit`; clean worktree.
- If pointer interception persists, patch only from geometric evidence; do not hide Hangouts (scope not approved).
- Actual desktop browser 200% and 400% verification, including G3-002 composer/Report/End, remains **NOT VERIFIED**.
- Manual screen reader verification remains **NOT VERIFIED**.
- Groups 6–9 populated state coverage remains **NOT VERIFIED**.
- Security, infrastructure and cross-team integration remain delegated; no merges/deployments approved.

## Handoff

Team 5D must not integrate this isolated UX branch until exact-SHA checks succeed and conflicts with approved security/core changes have been resolved. PR #301 is deliberately unmerged and must not be merged wholesale.
