# T-A13 — Multilingual Evaluation Executor (Pre-Provider Protocol V1)

Status: **OFFLINE PRE-PROVIDER EXECUTOR READY**
Branch: `team13/multilingual-eval-executor-003`
Authority Boundary: T-A13 Multilingual Evaluation & Intelligence Research
Execution State: `WAITING_ON_AUTHORIZED_TERRA_EXECUTION_SURFACE`
Live Provider Calls: `LIVE_TERRA_REQUESTS = 0` (Strictly enforced)

---

## 1. Protocol Architecture & Invariants

T-A13 defines an offline-first, fail-closed evaluation pipeline designed for reproducible multilingual assessments across StrangerTalks core languages (`en`, `te`, `hi`).

```text
[Frozen Corpora & Hashes]
           │
           ▼
[Single Pre-Flight Gate] ──(Pass/Fail)──► Refuse Execution if FAIL
           │ (PASS)
           ▼
[T-A13 Executor Engine]
   ├─ Repeat Index Enforcement (1..N)
   ├─ Condition Pairing (C2: Baseline vs C3: Companion)
   ├─ Retry / Stop State Machine (Immediate abort on 429 / Discrepancy)
   └─ Overwrite Protection (Immutable directory storage)
           │
           ▼
[Blinded Adjudication Tooling] ──► Exports Option A / Option B with separate unblinding key
```

---

## 2. Required Frozen Provider Configuration

The executor enforces exact parameter match against the frozen specification. Any divergence triggers `T-A13 EXPERIMENT CONFIGURATION INCOMPATIBILITY`:

| Parameter | Frozen Value | Enforcement |
|:---|:---|:---|
| **Provider** | `OpenAI API` | Fail closed on mismatch |
| **Requested Model** | `gpt-5.6-terra` | `MODEL_IDENTITY_DISCREPANCY` if returned model differs |
| **Temperature** | `0.2` | Immutable |
| **Top P** | `1.0` | Immutable |
| **Top K** | `unsupported / not used` | Disabled |
| **Max Output Tokens** | `2048` | Immutable |
| **Seed** | `unsupported / not used` | Disabled unless explicitly supported |
| **Reasoning Effort** | `none` | Immutable |
| **Tools / Web / Computer / File Search** | `false / []` | Strictly prohibited (Text-to-text only) |

---

## 3. Frozen Corpora Counts and Hashes

Total Items: **131** across 3 corpora:

| Corpus | Expected Items | Language Breakdown | Frozen SHA-256 Hash |
|:---|:---|:---|:---|
| **ML CORE** | `104` | 40 EN / 32 TE / 32 HI | `7609fce3927b9d24b9491703a9064549decc5a4711ab488a3ff27dc3bd3f8f66` |
| **CTX** | `24` | 8 EN / 8 TE / 8 HI | `13785501eb2b2bd833c5c96de95c40af0e7e99207fb781a69e9f543776c0914b` |
| **SAFETY COLLISION** | `3` | 1 TE / 1 EN / 1 HI | `5c4a221136634eec248a6b892dfdf1c77ee57c7d66c163b3d08614daa89f9340` |
| **CONTROLS (C2/C3)** | `2 conditions` | C2 (baseline) / C3 (companion) | `1c9c34e11e605c8f90a7a0b170aa995db52e1095e5340c8860c4ff43cf5d43f6` |

---

## 4. Single Pre-Flight Gate

The executor **refuses** corpus execution until `Preflight.run/1` returns `{:pass, manifest}`:

1. Validates all corpus item schemas and exact counts (104, 24, 3).
2. Computes file SHA-256 hashes and compares against `frozen_hashes.json`.
3. Validates prompt controls for C2 and C3.
4. Validates frozen provider parameters.
5. Verifies provider state is `WAITING_ON_AUTHORIZED_TERRA_EXECUTION_SURFACE`.

---

## 5. State Machine & Overwrite Protection

- **Stop Conditions**:
  - `429 credit_balance_exhausted` -> Immediate pipeline abort.
  - `MODEL_IDENTITY_DISCREPANCY` -> Immediate pipeline abort.
  - `T-A13 EXPERIMENT CONFIGURATION INCOMPATIBILITY` -> Immediate pipeline abort.
  - `result_already_exists` -> Immediate pipeline abort (never overwrite).
- **Transient Retries**:
  - Max 3 attempts for network timeouts or 5xx HTTP codes on the same item.
- **Repeat Index Enforcement**:
  - Requires integer `repeat_index in 1..max_repeats`.
- **C2/C3 Pairing Enforcement**:
  - Every completed run requires that all items contain paired records for both C2 and C3 conditions.
- **Immutable Storage**:
  - Results stored in `priv/evaluation/results/<run_id>/<corpus>/<item_id>/repeat_<repeat>_<condition>.json`.
  - Raw provider payloads stored verbatim in `..._raw.json` with preserved `request_id` and `response_id`.

---

## 6. Blinded Adjudication Export Tooling

`StrangertalksNew.Evaluation.Adjudication.export_run/3`:
- Consumes paired C2 and C3 results.
- Blinds condition names into `option_A` and `option_B` using deterministic shuffling.
- Emits `adjudication_export.json` for human raters (zero condition labels).
- Emits `adjudication_key.json` stored separately for downstream unblinding.

---

## 7. Exact Run Inventory & Dry-Run Verification

### Frozen Execution Inventory Breakdown
- **CORE C2**: 234 primary runs (78 items × 3 repeats)
- **CTX C2**: 72 primary runs (24 items × 3 repeats)
- **CTX C3**: 72 primary runs (24 items × 3 repeats)
- **C4**: 48 primary runs (24 items × 2 repeats)
- **SAFETY COLLISION**: 18 primary runs (3 items × 6 runs)
- **FULL PRIMARY TOTAL**: **444** primary runs
- **Pilot**: **24** primary runs (stored separately, does not reduce full-run requirement)
- **C1**: `NOT_APPLICABLE_CURRENT_MAIN` (no static phrasebook)

### Dry-Run Verification
Dry-run execution uses `MockProvider` and mechanically proves:
```text
LIVE_TERRA_REQUESTS = 0
```
- Pilot: Evaluates 24 primary runs with 0 live requests into isolated pilot storage.
- Full run: Evaluates 444 primary runs across frozen conditions with 0 live requests.
