# StrangerTalks Team 5F RC0 — D8 repository-only rehearsal

Founder D8 explicitly approved creating and testing one repository-only release branch. No merge, staging/production deploy, live database or configuration changes, restart, spending or real user invitation is approved.

## Source provenance

- main: `c7e750b4bd0fbf5f92ff1a0cabc728ce08d4fe66` (includes already merged responsive PR #295)
- core: `2cd878d0f25392d17bf58e741376dc578a40a6c3`
- security: `bff5ebc0ee4f860050482705f836b5d762f11cdf`
- ux: `33ed8dd99410a73dbcdf2f7d273de93842971e00`
- cache: `940bd6f2327c53a48ff202460dcff21044a49071`

Integration uses changed-file snapshot overlay on main with a single-parent commit (not source-branch merge ancestry). Source diff manifests contain 19 core, 19 security, 10 UX and 2 credential-cache paths; only `config/test.exs` overlaps. The integrated tree preserves main's final PR #295 CSS.

## Conflict resolution

`config/test.exs`: preserve narrow test-only `127.0.0.1`/localhost Phoenix Origin restrictions, test-server-only bounded synthetic participant issuance, and enabled Hangouts fixtures for isolated `MIX_ENV=test` tests. Production Hangouts runtime remains default-off.

## Evidence and limits

- Core original `37793776634`: exact-SHA PASS.
- Security original `37793717614` plus 8 others: exact-SHA PASS.
- UX source PR #306 `33ed8dd9...`: corrective formatter commit; browser workflow was still running when selected, therefore not accepted until integrated tests.
- Newer PR #305 security lifecycle/proxy changes deliberately excluded pending whole-branch acceptance; do not separately replay ancestor PR #302.
- No real 200%/400% desktop zoom or manual screen-reader certification.
- No integrated source test is claimed PASS before complete CI.
- Production DB identity and staging isolation, human moderation, adult policy and retention scheduler remain NO-GO.

## Acceptance checks

Complete exact-SHA Phoenix precommit, JavaScript, real two-browser and terminal/reconnect, disabled Hangouts authenticated WSS, credential-cache, PostgreSQL fault and BEAM restart tests, isolated PG17 release build and clean worktree.
