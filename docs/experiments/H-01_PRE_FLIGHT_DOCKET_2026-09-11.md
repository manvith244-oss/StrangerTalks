# EXPERIMENT RUN SHEET: H-01 (PROTOTYPE 1 INITIAL RENDEZVOUS)

Status: PRE-FLIGHT FROZEN — DO NOT ACTIVATE WITHOUT SEPARATE OWNER AUTHORITY

================================================================================
EXPERIMENT RUN SHEET: H-01 (PROTOTYPE 1 INITIAL RENDEZVOUS)
================================================================================
Canonical Base:     075550b8651b3d84f4b53897df106f460e141713
Target Endpoint:    /lab/hearth (flag-gated)
Assignment:         Deterministic 50/50 ("auto" via participant_id hash)
Cohort Type:        Synchronized External Rendezvous (Zero Organic Drift)

ARCHETYPE:          Failed Aspiration (Physical Clutter Variant)
PROMPT:             "What did you buy convinced you'd use it, that is currently just taking up space?"
LATENT AXIS:        Aspirational self-image vs. domestic reality / habit friction.
EXIT SEAM:          Daily survival routines, abandoned ambitions, money psychology.

STOPPING CRITERIA (Whichever occurs first):
1. Cumulative Completed Encounters = 50 (approx. 25 Control / 25 Treatment).
2. Elapsed Window Time = 90 minutes.

EVALUATION HARNESS:
- Primary Positive Signal:
  * Treatment decreases demographic openings (Turn 1–3 ASL/location) by >= 50% vs. Control.
  * Treatment median turn depth past Turn 6 exceeds Control by >= 30%.
- Primary Negative Signal:
  * Equivalent or worse early drop-off rate (<= 2 turns) in Treatment vs. Control.
  * Topic failure: Treatment conversations stay trapped on product specs without migrating.

SAFETY & PRIVACY INVARIANTS:
- No chat message text or raw prompt inputs persisted or emitted to telemetry.
- Exit feedback strictly categorical (5 frozen enum choices, non-blocking).
================================================================================

## Operational pre-flight

1. Assemble a synchronized external cohort, nominally 40–60 participants, for one planned 60–90 minute window.
2. Use an isolated preview/staging deployment based on canonical `main@075550b8651b3d84f4b53897df106f460e141713`.
3. Enable `EXPERIMENT_HEARTH_ENABLED=true` only in that isolated experiment environment for the live window.
4. Direct participants straight to `/lab/hearth`; do not split or reroute canonical organic traffic.
5. End the run at the first stopping criterion reached.
6. Disable `EXPERIMENT_HEARTH_ENABLED` immediately after the run.
7. Export only the privacy-bounded discrete event telemetry defined by the Prototype 1 contract.
8. Compare Control vs. Treatment on demographic-opening rate, median turn depth, early drop-off, exit-reason distribution, and qualitative context-migration sampling.

## Hard operational prohibitions

- Do not enable this experiment on the current production Phoenix service as part of pre-flight preparation.
- Do not mutate Supabase, production database schema, or production secrets for H-01.
- Do not enable organic traffic splitting.
- Do not change cohort assignment away from server-side deterministic `variant: "auto"` during the run.
- Do not persist raw chat bodies or raw Hearth responses in analytics, logs, or experiment storage.
- Do not change the prompt, stopping criteria, or success/kill thresholds after exposure begins.
- Do not continue past 50 completed encounters merely to chase statistical significance.

## Interpretation boundary

H-01 is a directional falsification experiment, not a statistically powered population study. A positive result authorizes consideration of Archetype 2; it does not prove the complete World/Relationship theory. A null or negative result requires prompt/mechanic diagnosis before expanding the experiment surface.

## Founder decision already frozen

- Repository admission of the dormant Hearth harness: COMPLETE in `main@075550b8651b3d84f4b53897df106f460e141713`.
- Organic production split: REJECTED.
- H-01 execution mode: synchronized, time-bounded external Rendezvous Trial in an isolated/controlled deployment.
- H-01 live activation: NOT YET AUTHORIZED BY THIS DOCUMENT.
