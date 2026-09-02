# Complete StrangerTalks Reconciliation Design

## Goal

Create one local reconciliation candidate that preserves the broadest prep product, composes the later integration line through a real merge, and then ports every compatible validated specialist delta without changing existing release branches or external systems.

## Fixed authorities

- Starting base: `origin/release/prep-2026-08-22` at `2724d655a1ab7502c0caa39c91644cd6559a5f96`.
- First merge input: `origin/release/integration-2026-08-28` at `f781a0796e68db26409c1744d7633a22cc6b11d0`.
- Candidate branch: `reconcile/complete-strangertalks-2026-09-01`.
- Existing branches, GitHub, Render, and production infrastructure remain untouched.

If either release ref moves, reconciliation stops before further composition.

## Composition architecture

The candidate is built in independently verifiable layers:

1. **Prep baseline:** record the exact environment and test behavior before merging.
2. **Release composition:** merge integration into prep with a two-parent merge commit. Resolve conflicts by preserving observable contracts from both branches, not by selecting one side wholesale.
3. **Database and authority wave:** atomic pairing reservations, pre-identity abuse controls, participant credential revocation, and retention cleanup. Migrations must be additive and non-destructive.
4. **Lifecycle and communications wave:** terminal hardening, durable Block truth, call/media authority, and hostile normal-media behavior. Later prep/integration call and terminal contracts remain authoritative unless the specialist change adds a compatible invariant.
5. **Client safety and UX wave:** inert reaction DOM construction, secondary Settings reconciliation, and focus-race correction. Existing route, shell, risk-gradient, expression-continuity, draft, and motion behavior must survive.
6. **Bounded services and operations wave:** Python AI boundary and release health/version authority, only where they preserve Phoenix authority. TLS remains deferred without conclusive operational proof.

Each layer ends with focused tests and a narrow local commit. A failing or ambiguous layer does not contaminate later layers.

## Conflict policy

For each conflict, inspect the merge base, prep version, integration version, relevant tests, and commit intent. Compatible behaviors are combined. A conflict stops the run when it encodes incompatible product policy, lifecycle law, safety authority, destructive migration behavior, or an unclear test contract.

High-risk surfaces include `priv/static/index.html`, `app.js`, `app.css`, routing/history, session reconciliation, Conversation lifecycle, Terminal Truth, WebRTC, normal media, Settings, expressions, and focus behavior.

## Verification architecture

- Prep baseline: dependency/setup checks, compilation, ExUnit, maintained Node suites, available browser suites, `mix precommit`, and `git diff --check`.
- Post-merge gate: repeat the broad maintained matrix and classify every failure against both parents.
- Specialist gates: run focused tests from each source delta before the broad gate.
- Final gate: compile, all ExUnit, maintained JS and browser suites, PostgreSQL concurrency/retention/credential tests, Python boundary tests if integrated, `mix precommit`, and `git diff --check`.

No live OpenAI call is required. No production database, secret, push, PR, or deployment operation is permitted.

## Stop and defer rules

Stop on moved release refs, unresolved product policy, incompatible lifecycle law, weakened safety invariants, destructive migrations, unclear regression behavior, or any Python path to PostgreSQL/matchmaking/lifecycle/safety mutation. Defer TLS unless repository and environment evidence prove it safe for both local and deployed database behavior.

