# T04 — Identity, Security, Privacy & Safety Engineering Authority

## Evolution Clause

Security mechanisms, legal requirements and identity architecture may evolve. Product-level decisions about anonymity, disclosure, children, retention and safety remain explicit governance decisions; engineering must adapt without silently weakening user expectations.

## Mission

Protect StrangerTalks' unusual trust model: users may enter without public identity, disclose selectively, preserve private continuity, and still remain subject to enforceable private accountability and abuse controls.

## Owned authority

- authentication/session engineering;
- authorization and access checks;
- participant credential lifecycle;
- identity-linking technical boundaries;
- scoped identity enforcement;
- Block/Report/safety data access engineering;
- retention/deletion implementation after policy is approved;
- secrets and encryption boundaries;
- rate limits and abuse friction;
- security testing;
- privacy-safe logs/telemetry/data flow.

## Product boundaries to preserve

- anonymity means control over automatic/public linkage, not a platform promise that consenting humans can never disclose themselves;
- private relationships must not automatically expose activity elsewhere;
- Block/safety vetoes must survive user-facing identity limitations;
- AI/analytics do not receive broader identity/content access merely because they are internal.

## Immediate archaeology inputs

Inspect:

- account/session and participant token code;
- continuity/account-link branches;
- safety review concurrency work;
- terminal truth/Block lineages;
- privacy storage map;
- `team7/privacy-retention-2026-08-26`;
- local encryption/export/import/sync work;
- media access/privacy code;
- latest India legal validation before freezing retention/children/notice behavior.

## Priority reconciliation

The branch-only retention implementation is technically substantial but contains policy values that must be reconciled with:

- latest product decisions;
- current schema;
- current safety evidence lifecycle;
- current legal/regulatory analysis.

Do not merge retention durations as if they are merely code constants.

## Required threat cases

- credential replay;
- stale token after account link/logout/revocation;
- cross-participant access;
- cross-context identity correlation;
- Block evasion;
- report/safety evidence leakage;
- media URL/object access after authority ends;
- rate-limit bypass/multi-account abuse;
- secrets in logs/CI artifacts;
- telemetry containing private content;
- backup/export tampering;
- deletion/retention partial failure.

## Technology posture

- authentication/authorization/access control: ACTIVE NOW;
- encryption/secrets management: ACTIVE requirements;
- rate limiting: ACTIVE/REQUIRED on abuse-sensitive surfaces;
- external identity provider additions: product/architecture decision, not default;
- zero-trust/service auth becomes more important as services are extracted;
- centralized secrets tooling/IaC: T08 coordination as infrastructure grows.

## Evidence

Require backend authorization tests, hostile cross-user tests, revocation tests, privacy/logging tests, retention database tests where applicable, security dependency review and exact-SHA handoff.

## Stop conditions

Stop for Owner/Product/Legal decision when engineering would change user-visible anonymity, disclosure, retention, children eligibility, report handling or safety policy.
