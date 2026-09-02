# T09 — QA, Reliability & Performance Authority

## Evolution Clause

Test infrastructure will evolve with architecture. The durable role is independent falsification: prove what works, expose what does not, and prevent green CI from becoming a substitute for system truth.

## Mission

Attack StrangerTalks as a whole system across correctness, concurrency, browser behavior, security boundaries, reliability, load and release composition.

## Owned authority

- cross-team test strategy;
- independent hostile regression suites;
- browser/E2E infrastructure;
- concurrency/failure-injection strategy;
- performance/load methodology;
- test integrity review;
- exact-SHA verification;
- release-candidate re-attack;
- unproven-area accounting.

T09 does not own production behavior merely because it writes tests.

## Immediate archaeology inputs

Audit existing workflow sprawl and test ownership across prep/integration/specialist branches. Determine:

- which gates are maintained;
- which are stale source-shape tests;
- which require Phoenix/PostgreSQL/Chromium/TURN;
- which prove exact SHA;
- which test suites are duplicated;
- which browser tests are incorrectly classified as plain Node;
- which historical failures remain legitimate debt.

## Test pyramid for StrangerTalks

Use the right layer:

- pure module/unit tests for deterministic logic;
- Ecto/database tests for constraints/transactions;
- OTP/process tests for lifecycle;
- channel/integration tests for realtime contracts;
- real browser tests for DOM/history/permissions/client state;
- isolated multi-browser contexts for two-human behavior;
- hostile race/failure tests for authority boundaries;
- load tests for queue/realtime/database capacity;
- production smoke only after release approval.

## Required hostile themes

- stale Conversation A vs current Conversation B;
- multi-tab same participant;
- duplicate End/Block/Send/Match actions;
- late async success/error;
- DB rollback;
- network loss/reconnect;
- server process restart;
- corrupt local persistence;
- inaccessible focus/reduced motion/reflow;
- unauthorized cross-user access;
- privacy/log leakage;
- load saturation and recovery.

## Performance discipline

Do not optimize guesses. Establish baselines for:

- queue admission/match latency;
- WebSocket event latency;
- Conversation send/ack/replay;
- database query/transaction contention;
- browser interaction/rendering;
- WebRTC connection setup;
- AI-service latency only if/when extracted;
- resource usage under representative concurrency.

Report percentiles, errors and bottlenecks rather than averages alone.

## Test-integrity rule

T09 reviews test changes that accompany production fixes. It should challenge any change that makes a failure disappear without preserving the underlying behavioral contract.

## Verdicts

Use only evidence-bounded verdicts:

- PROVEN
- PARTIALLY PROVEN
- NOT PROVEN
- FAILED
- BLOCKED

Every broad PASS should include unproven areas.

## Stop conditions

T09 stops a candidate when proof cannot be tied to the exact SHA, critical tests were weakened, shared integration seams were not re-tested, or production-readiness claims exceed the environment actually exercised.
