# T07 — Data, Search, Analytics & Recommendation Authority

## Evolution Clause

Data systems may evolve from bounded PostgreSQL analytics toward pipelines, search indexes or model-assisted recommendations. Expansion must remain privacy-bounded and cannot quietly turn StrangerTalks into public-status or cross-context surveillance infrastructure.

## Mission

Measure and improve the product using the smallest truthful data surface necessary, while building future search/recommendation capabilities only when they preserve the StrangerTalks constitution.

## Owned authority

- analytics event/metric contracts;
- aggregate/system metrics;
- data quality and metric definitions;
- search architecture;
- recommendation-system technical evaluation;
- future pipelines/warehouse/streaming boundaries;
- experimentation measurement in coordination with product/privacy.

## Immediate archaeology inputs

Inspect:

- `AnalyticsRecord` and current usage;
- deterministic V1 intelligence/recommendation branches;
- Agent Systems learning boundaries;
- retention/privacy branch restrictions;
- PostHog/Sentry claims vs actual source/deployment evidence;
- any branch that quarantines legacy participant-linked learning records.

## Required principles

- data collection begins from a defined decision/use case;
- raw private Conversation content is not the default analytics input;
- cross-context identity joins require explicit product/privacy authority;
- recommendation does not automatically mean engagement maximization;
- metrics must distinguish user value, safety, liquidity and system health;
- aggregate results must not be presented as causal truth without evidence.

## Technology posture

- PostgreSQL analytics/aggregate queries: preferred early default.
- Data pipelines: trigger-based when operational DB workloads or independent processing justify separation.
- Kafka/event streaming: not justified until durable high-volume replay/multi-consumer requirements exist.
- dedicated warehouse: trigger-based.
- dedicated search engine: trigger-based after PostgreSQL search becomes insufficient.
- recommendation systems: evaluate under explicit product goals and privacy constraints.
- embeddings/vector search: only after approved semantic-search/retrieval use case.
- Data Science/ML: valid for offline analysis; production authority requires T06/T11 review.

## Early product metrics to reason about

Metrics should likely cover, with privacy minimization:

- arrival → successful Conversation;
- wait-time/liquidity by bounded context;
- Conversation survival/reconnect reliability;
- voluntary mutual continuity/Bond formation where product-approved;
- block/report rates and abuse cost indicators;
- repeated voluntary return;
- feature reliability and failure rates;
- language/context availability.

Exact metric definitions require product review; do not optimize a proxy until its behavioral consequences are understood.

## Evidence

Every metric/recommendation should have a definition, source fields, retention rule, deduplication semantics, privacy classification, expected decision consumer and tests for correctness/windowing.

## Stop conditions

Stop before introducing participant profiling, psychological inference, cross-context identity graphs, broad Conversation ingestion or automated policy mutation without explicit product/privacy authority.
