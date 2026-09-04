# Agent Provider Probe Failure Isolation Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Prevent optional external Agent-provider verification from controlling core Phoenix application availability while preserving explicit provider verification.

**Architecture:** Keep `StrangertalksNew.Application.start/2` responsible only for starting deterministic StrangerTalks runtime children. Preserve `StrangertalksNew.AgentSystems.ProviderProbe` as an explicit verification capability, and prove with a real application-start harness that provider failures no longer stop the core supervisor.

**Tech Stack:** Elixir/OTP, Phoenix, ExUnit-compatible proof harness, GitHub Actions, PostgreSQL 16.

**Spec:** Agent Command packet `T-A04-002 — AGENT PROVIDER PROBE FAILURE-ISOLATION CLOSURE`; operational boundary reference `docs/PRODUCTION_OPERATIONS.md`.

## Global Constraints

- Canonical base: `423442915e37fd6aadd25bd1c6a300eed2b464f0` unless repository truth advances before execution.
- Do not modify model-backed A02 privacy remediation lineage.
- Do not migrate A01–A04 to Python.
- Do not add generic Agent routing, provider failover, circuit breaking, concurrency controls, cost controls, or new provider infrastructure.
- Do not deploy or modify Render environment variables.
- Do not log API keys, authorization headers, prompts, participant content, transcripts, or raw provider payloads.
- TDD: preserve a RED exact-SHA proof before production code changes.

---

### Task 1: Prove current boot coupling

**Files:**
- Create: `test/proofs/provider_probe_boot_isolation.exs`
- Create: `.github/workflows/t-a04-provider-probe-isolation.yml`

**Interfaces:**
- Consumes: `StrangertalksNew.Application.start/2`, `StrangertalksNew.AgentSystems.ProviderProbe.run/0`.
- Produces: exact-SHA RED evidence showing a failing enabled provider prevents real application startup on the canonical implementation.

- [ ] **Step 1: Write the failing boot-isolation proof**

Use `mix run --no-start test/proofs/provider_probe_boot_isolation.exs` under `MIX_ENV=test`. The script must configure an enabled deterministic failing provider, start the real OTP application via `Application.ensure_all_started(:strangertalks_new)`, assert the core supervisor/representative deterministic children are alive, and separately assert explicit `ProviderProbe.run/0` reports the provider failure.

- [ ] **Step 2: Run the proof on unmodified production code**

Expected: FAIL because current `Application.start/2` stops `StrangertalksNew.Supervisor` after the probe error.

- [ ] **Step 3: Preserve exact-SHA RED evidence**

Record workflow run ID, commit SHA, job logs and causal failure.

### Task 2: Remove provider health from runtime-start authority

**Files:**
- Modify: `lib/strangertalks_new/application.ex`
- Modify: `lib/strangertalks_new/agent_systems/provider_probe.ex` only if documentation must be corrected; do not change probe result semantics.
- Modify: `docs/PRODUCTION_OPERATIONS.md` only if needed to make the explicit verification boundary unambiguous.

**Interfaces:**
- Consumes: unchanged `ProviderProbe.run/0` explicit verification API.
- Produces: `Application.start/2` that returns the core supervisor start result without invoking or stopping it based on provider health.

- [ ] **Step 1: Implement the smallest production change**

Remove boot-time `ProviderProbe.run/0` ownership from `Application.start/2`; do not add fallback product behavior.

- [ ] **Step 2: Re-run the boot proof**

Expected: PASS. Provider failure remains visible through explicit `ProviderProbe.run/0`, while Phoenix core remains alive.

### Task 3: Prove failure matrix and regressions

**Files:**
- Modify: `test/strangertalks_new/agent_systems_provider_probe_test.exs` only for missing explicit probe classifications.
- Modify: `.github/workflows/t-a04-provider-probe-isolation.yml` to run the required focused matrix and `mix precommit`.

**Interfaces:**
- Consumes: isolated runtime start and unchanged Agent fail-closed behavior.
- Produces: exact-SHA GREEN proof and clean-checkout precommit evidence.

- [ ] **Step 1: Prove probe disabled + provider unavailable**

Core application must start without any provider request.

- [ ] **Step 2: Prove enabled explicit verification success**

`ProviderProbe.run/0` returns `:ok` while core remains alive.

- [ ] **Step 3: Prove explicit provider failures do not stop core**

Cover connection failure, timeout, authentication failure, 429/unavailable, 5xx/unavailable, malformed response, and schema/semantic-invalid result classifications through the narrowest existing provider/probe seams.

- [ ] **Step 4: Prove restart during outage and provider recovery**

Stop/start the real application with provider still failing, assert deterministic children return, then switch the fake provider to success and assert explicit verification succeeds without another Phoenix restart.

- [ ] **Step 5: Run regressions**

Run focused ProviderProbe tests, A01 disabled/unavailable-provider regressions, representative deterministic core tests, and full `mix precommit`.

- [ ] **Step 6: Prove checkout cleanliness**

`git status --porcelain` must be empty after precommit.

- [ ] **Step 7: Record exact-SHA CI evidence**

Record final SHA, tree SHA, workflow run ID, test counts, and conclusions. Do not deploy.
