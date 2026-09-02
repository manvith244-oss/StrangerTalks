# 00 — StrangerTalks Construction Charter

Status: UNIVERSAL / REQUIRED

## 1. Mission

Build StrangerTalks as a technically strong, privacy-conscious, human-scale social system in which context can precede identity, conversation can precede audience, access is mutual rather than extractive, and relationships may persist without automatically becoming public social graphs.

The construction system exists to turn product intent into verifiable implementation without losing prior work, confusing branch history with truth, or allowing AI/human teams to silently change product law.

## 2. Current product laws

Unless an explicit later decision supersedes them, construction must preserve these principles:

- Context before identity.
- Conversation before audience.
- Mutuality before access.
- Anonymous or pseudonymous entry must not require public identity.
- Identity disclosure is voluntary and contextual.
- Private Encounters remain first-class.
- Mutual continuity may preserve access between humans.
- Identity does not automatically travel across contexts.
- Relationships may become personally known without becoming public graphs.
- Meaning may travel without automatically carrying identity.
- Safety authority must remain enforceable even where user-facing identity is limited.
- Large participation should preserve human-scale local interaction rather than defaulting to audience/status mechanics.
- Public profiles, followers, portable social status and engagement-maximizing reach are not assumed as the organizing architecture.

These are construction constraints, not excuses to preserve weak implementations. Teams may propose better mechanisms that uphold the same law.

## 3. Engineering principles

1. **Evidence before assumption.** Read code, tests, PR history, branches and architecture records before claiming current behavior.
2. **Authority must be explicit.** Every mutable state needs a clear canonical owner: database, process, service, browser or external provider.
3. **Fail closed at safety and authority boundaries.** Ambiguity must not create access or weaken a safety veto.
4. **Preserve concurrency correctness.** Realtime social systems must be designed for races, retries, duplicate operations, stale callbacks and multi-device/multi-tab behavior.
5. **Prefer the simplest architecture that preserves correctness.** A modular monolith is acceptable; microservices are not a maturity badge.
6. **Extract only earned boundaries.** Service extraction requires a concrete operational, scaling, security, dependency or organizational reason.
7. **Privacy is architectural.** Retention, logs, analytics, AI payloads, identifiers and telemetry must be designed together.
8. **AI is advisory unless explicitly granted authority.** Model output must not silently become product authority.
9. **No test weakening to make a branch green.** Repair implementation or stale test contracts deliberately and explain which one changed.
10. **No fake proof.** Exact-SHA, clean-tree, real browser, integration, concurrency and production claims must match the evidence actually collected.

## 4. Construction over feature accumulation

Teams should not optimize for number of features. The priority order is:

- establish truth;
- establish ownership and authority;
- make the smallest important experience excellent;
- prove reliability and safety;
- then expand the surface.

Features that multiply complexity, liquidity fragmentation, abuse reach, privacy risk or operational burden require explicit justification.

## 5. Branch-independent truth

`main`, `master`, `release/prep-*`, `release/integration-*`, feature branches and historical team branches are evidence sources. None is automatically the whole product.

Unmerged work may contain important implementation or proof. Merged work may later be superseded. Diagnostic branches may look newer while carrying no product authority.

Repository truth is reconstructed under `01_REPOSITORY_TRUTH_PROTOCOL.md`.

## 6. Universal role model

The construction system separates roles:

- Owner
- Orchestrator
- Owner Proxy
- Prompt Compiler
- Executor
- Verifier / Break Team
- Integration Authority

One agent may technically perform more than one role in low-risk work, but role boundaries must remain conceptually explicit. High-risk changes should separate execution from verification.

## 7. Evolution clause

The end goal may change.

That is expected.

StrangerTalks may evolve because research changes the product thesis, users behave differently than expected, laws change, abuse appears, costs change, scale changes, or better technical mechanisms become possible.

Therefore:

- documents describe the **best current construction direction**, not eternal truth;
- implementation decisions may be challenged with evidence;
- product laws may evolve only through explicit owner/product governance;
- major architecture changes require an ADR or equivalent decision record;
- superseded assumptions must be marked rather than silently rewritten as if they never existed;
- migrations must preserve safety, data and authority invariants during transition.

**Evolution is allowed. Silent drift is forbidden.**
