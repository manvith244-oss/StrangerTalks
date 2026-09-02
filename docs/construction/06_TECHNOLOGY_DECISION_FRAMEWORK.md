# 06 — Technology Decision Framework

Status: UNIVERSAL / LIVING DOCUMENT

## Purpose

StrangerTalks should be technically strong, but technical strength does not mean adopting every enterprise technology.

This document converts the broad engineering vocabulary into an explicit decision system.

## Status vocabulary

Every technology/domain may be classified as:

- **ACTIVE NOW** — present in current accepted application behavior or tooling.
- **ACTIVE SUPPORTING TOOL** — used for development/testing/operations but not a production architecture boundary.
- **BRANCH-ONLY / SALVAGE CANDIDATE** — implemented or substantially prototyped outside the current construction baseline.
- **ADOPT NOW** — justified immediately by a concrete requirement.
- **PLANNED BOUNDARY** — architecture should preserve a clean seam, but implementation is not required yet.
- **TRIGGER-BASED FUTURE** — adopt only when a defined scale/product/operational trigger is reached.
- **EVALUATE** — evidence is insufficient; run a focused decision process if the need appears.
- **NOT JUSTIFIED** — no current problem warrants the complexity.
- **INCOMPATIBLE / REJECTED** — conflicts with current product or architecture law unless that law changes.

A technology may move between states through an ADR.

## Adoption questions

Before adding a material technology, answer:

1. What exact problem exists?
2. Can the current stack solve it safely and simply?
3. What scale or reliability requirement forces a new boundary?
4. What new operational burden appears?
5. What failure modes are introduced?
6. Who owns the component?
7. How is it secured?
8. How is it observed?
9. How is it tested locally and in CI?
10. How is it deployed, rolled back and migrated?
11. What data crosses the boundary?
12. What would cause us to remove or replace it?

## Current evidence-backed platform direction

### Application architecture

- **Backend / Full Stack / Product Engineering — ACTIVE NOW.**
- **Elixir — ACTIVE NOW.**
- **Phoenix — ACTIVE NOW.**
- **Ecto / SQL — ACTIVE NOW.**
- **PostgreSQL — ACTIVE NOW and current durable authority store.**
- **JavaScript — ACTIVE NOW for browser/client runtime.**
- **HTML/CSS — ACTIVE NOW.**
- **WebSockets / Phoenix Channels — ACTIVE NOW for realtime interactions.**
- **OTP processes / supervision — ACTIVE NOW and should remain a first-class realtime/concurrency primitive.**
- **Modular Monolith — preferred current social-core direction.** Existing code should be made more modular before extracting services simply for fashion.
- **Microservices Architecture — TRIGGER-BASED FUTURE.** Extract only earned boundaries.
- **SOA — EVALUATE as a conceptual boundary pattern; do not create a service estate without need.**

### HTTP/API surface

- **APIs — ACTIVE NOW.**
- **REST-style HTTP — ACTIVE NOW where controllers/endpoints fit the use case.**
- **GraphQL — NOT JUSTIFIED currently.** Reconsider if multiple independently evolving clients need flexible aggregate queries that REST/realtime contracts cannot serve cleanly.
- **API Gateway — TRIGGER-BASED FUTURE.** Useful after multiple independently deployed external/internal services exist.
- **Service Mesh — NOT JUSTIFIED currently.** Reconsider only after a meaningful multi-service estate creates service-to-service security/observability problems.

### Realtime / distributed

- **Realtime Systems — ACTIVE NOW.**
- **WebRTC — ACTIVE NOW / specialist media authority; continue archaeology and production verification.**
- **Pub/Sub — ACTIVE conceptually through Phoenix/OTP primitives; external broker not automatically required.**
- **Event-Driven Architecture — ACTIVE as a design technique where lifecycle events are appropriate; avoid turning every function call into an event.**
- **Distributed Systems — ACTIVE concern even before many services because realtime processes, browsers, databases and network failure create distributed-state problems.**
- **Message Queues — PLANNED BOUNDARY / EVALUATE.** Adopt when durable asynchronous work requires independent retry/backpressure.
- **Kafka — NOT JUSTIFIED currently.** Trigger may be high-volume durable event streaming, independent consumers, replay and partitioned throughput that PostgreSQL/OTP/background jobs cannot reasonably serve.
- **RabbitMQ — NOT JUSTIFIED currently.** Trigger may be durable brokered work routing with delivery semantics that simpler queues cannot serve.
- **Background Jobs / Workers — EVALUATE/ADOPT where durable asynchronous operations appear.** Choose the smallest Elixir-native solution first unless workload isolation earns a service.
- **Cron Jobs — ACTIVE/PLANNED only for bounded operational tasks such as retention/maintenance when formally scheduled.
- **Event Bus — PLANNED BOUNDARY rather than a required product component.**

### Data

- **Databases — ACTIVE NOW.**
- **SQL — ACTIVE NOW.**
- **PostgreSQL — ACTIVE NOW.**
- **NoSQL — NOT JUSTIFIED currently as a general second datastore.**
- **Redis — EVALUATE, not assumed active.** Adopt only for a measured need such as shared ephemeral coordination/cache/rate state that OTP/PostgreSQL cannot meet at required topology/scale.
- **Caching — TRIGGER-BASED.** Measure first; cache authoritative data only with explicit invalidation and stale-read semantics.
- **Vector Databases — NOT JUSTIFIED currently.** Trigger only from an approved retrieval/semantic-search use case with privacy architecture.
- **Storage / File Storage — ACTIVE concern for media/operations.**
- **Object Storage — TRIGGER-BASED / likely future for durable bounded media/artifacts if product law permits; requires retention and access controls.
- **Backup / Disaster Recovery — ACTIVE production concern.**

### Search / recommendation / analytics

- **Analytics — ACTIVE but privacy-bounded; current archaeology includes deterministic/aggregate work.**
- **Search Engines — NOT JUSTIFIED as a separate engine yet.** PostgreSQL search may be enough for early bounded discovery. Trigger on corpus/latency/relevance needs.
- **Recommendation Systems — EVALUATE only under product and privacy law.** Relevance must not quietly become public-status or surveillance architecture.
- **Data Engineering / Data Pipelines — TRIGGER-BASED.** Introduce as data volume and independent analytical workloads justify them.
- **Data Science — EVALUATE for product research/measurement; not automatically production authority.

### AI / ML

- **AI / LLMs — ACTIVE in bounded existing Agent Systems and provider integrations.**
- **Agents — ACTIVE in a deliberately bounded advisory model, not autonomous product authority.
- **Multi-Agent Systems — ACTIVE as a development/orchestration methodology; NOT automatically a production social-product runtime.
- **Python — BRANCH-ONLY / SALVAGE CANDIDATE for an internal AI service boundary; also valid as tooling.
- **FastAPI — BRANCH-ONLY / SALVAGE CANDIDATE with the Python AI-service packet.
- **Django — NOT JUSTIFIED.**
- **RAG — NOT JUSTIFIED until a concrete private corpus/retrieval problem exists and retention/access rules are defined.
- **Embeddings — same trigger as RAG/semantic search.
- **Vector Databases — same trigger as RAG/semantic search.
- **MCP — EVALUATE for tool integration/orchestration; do not use as hidden product authority.
- **Prompt Engineering — ACTIVE discipline for development and bounded LLM features.
- **Model Serving — TRIGGER-BASED.** External provider boundary is sufficient until cost, privacy, latency or model-control requirements justify internal serving.
- **MLOps — TRIGGER-BASED.** Required only when StrangerTalks owns production models/data pipelines rather than bounded provider calls.

### Client technologies

- **Frontend / UX / UI / Accessibility / Localization / Internationalization — ACTIVE NOW and first-class product concerns.
- **Responsive Web — ACTIVE NOW.**
- **Mobile Development — PLANNED BOUNDARY.** Current responsive web can validate the product before native duplication.
- **Android / iOS — TRIGGER-BASED.** Native clients become justified by distribution, notifications, media/device integration, performance or retention benefits that materially exceed web.
- **React Native / Flutter — EVALUATE only when native strategy is approved; choose one based on team skills, native escape hatches and lifecycle/media requirements.
- **React / Next.js / Vue / Angular — NOT JUSTIFIED as frontend rewrites.** Current browser runtime should not be replaced without a clear maintainability/product reason and migration plan.
- **TypeScript — EVALUATE / potentially ADOPT as browser modules grow.** Requires migration value, not cosmetic rewriting.
- **Desktop Development — NOT JUSTIFIED as a separate native client yet.

### Other server languages/frameworks

- **Node.js — ACTIVE SUPPORTING TOOL for JS tests/tooling; not current core server authority.
- **C# / .NET — NOT JUSTIFIED currently.
- **Java / Spring Boot — NOT JUSTIFIED currently.
- **Go — EVALUATE only for a boundary with a measured fit such as high-throughput infrastructure where BEAM/Python are unsuitable.
- **Rust — EVALUATE only for a safety/performance-critical component that earns native complexity.

### Infrastructure / cloud

- **Git / GitHub / Version Control — ACTIVE NOW.**
- **Docker — ACTIVE NOW.**
- **CI/CD — ACTIVE NOW and heavily used for exact-SHA gates.
- **Deployment / Release Management / Staging / Production — ACTIVE concerns.
- **Cloud — ACTIVE production concern, provider details must be documented from actual deployment evidence.
- **AWS / Azure / GCP — EVALUATE, not architectural goals.** Choose a provider based on cost, operational requirements, region, compliance and services rather than prestige.
- **Kubernetes — NOT JUSTIFIED currently.** Trigger when service/container count, scheduling, availability and operations genuinely exceed simpler deployment platforms.
- **Serverless — EVALUATE for isolated bursty/event jobs, not the realtime authority core by default.
- **Edge Computing — TRIGGER-BASED for latency/global ingress/static/media concerns; avoid moving canonical mutable authority to edge casually.
- **Infrastructure as Code / Terraform — TRIGGER-BASED but likely valuable once production infrastructure becomes multi-resource and reproducibility matters.
- **NGINX / Reverse Proxy — ACTIVE/DEPLOYMENT-DEPENDENT; document actual current ingress before assuming topology.
- **Load Balancing — TRIGGER-BASED and required once multiple application instances are deployed.
- **CDN — TRIGGER-BASED for static/media/global performance.
- **DNS — ACTIVE operational dependency.
- **Networking — ACTIVE operational concern.

### Reliability / operations / security

- **Observability / Monitoring / Logging — ACTIVE and must remain privacy-conscious.
- **SRE / Reliability Engineering / Performance Engineering — ACTIVE disciplines even before dedicated staff exist.
- **DevOps / DevSecOps — ACTIVE disciplines.
- **Security — ACTIVE / universal concern.
- **Authentication / Authorization — ACTIVE NOW.
- **Identity Management / Access Control — ACTIVE NOW and product-critical.
- **Secrets Management — ACTIVE operational requirement.
- **Encryption — ACTIVE where required for transport/storage/export/credentials.
- **Rate Limiting — ACTIVE/REQUIRED on abuse-sensitive surfaces.
- **Firewalls — deployment-level requirement; document actual provider/network topology.
- **Feature Flags — EVALUATE/ADOPT for risky staged rollout where rollback by deploy is insufficient.

### Product/process/governance

- **Architecture / System Design — ACTIVE disciplines.
- **Testing / QA / Automation — ACTIVE NOW.
- **Agile / Scrum — OPTIONAL process tools, not product architecture. Use only if they improve execution.
- **Compliance / Privacy / Governance — ACTIVE and increasing in importance.

## Microservice extraction triggers

A module/service should be considered for extraction when several of these are true:

- materially different runtime/dependency stack;
- independent scaling profile;
- failure isolation is valuable;
- security boundary is clearer out-of-process;
- independent release cadence is necessary;
- ownership is independently staffed;
- resource demands interfere with the core BEAM runtime;
- external/internal protocol is already stable;
- operational benefit exceeds distributed-systems cost.

The branch-only Python/FastAPI AI boundary is a credible candidate because model dependencies and failure characteristics differ from the social/realtime core. It is still subject to salvage and integration proof.

## Rule for the technology vocabulary

The broad list — Microservices, Frontend, Backend, Full Stack, APIs, REST, GraphQL, WebSockets, Databases, SQL, NoSQL, Redis, Caching, Authentication, Authorization, Security, DevOps, DevSecOps, SRE, Cloud, AWS, Azure, GCP, Docker, Kubernetes, CI/CD, Infrastructure, Networking, Load Balancing, Scalability, Distributed Systems, Event-Driven Architecture, Message Queues, Kafka, RabbitMQ, Serverless, Edge Computing, Observability, Monitoring, Logging, Testing, QA, Automation, Performance Engineering, Reliability Engineering, Data Engineering, Data Science, Machine Learning, AI, LLMs, Agents, Multi-Agent Systems, RAG, Vector Databases, Embeddings, MCP, Prompt Engineering, Model Serving, MLOps, Data Pipelines, Analytics, Search Engines, Recommendation Systems, Real-Time Systems, WebRTC, Mobile Development, Android, iOS, React Native, Flutter, Desktop Development, .NET, C#, Java, Spring Boot, Python, Django, FastAPI, Node.js, JavaScript, TypeScript, React, Next.js, Vue, Angular, Go, Rust, Elixir, Phoenix, Git, GitHub, Version Control, Architecture, System Design, Monolith, Modular Monolith, Microservices Architecture, SOA, API Gateway, Service Mesh, Infrastructure as Code, Terraform, Secrets Management, Encryption, Identity Management, Access Control, Rate Limiting, Firewalls, CDN, DNS, Reverse Proxy, NGINX, Background Jobs, Workers, Cron Jobs, Pub/Sub, Event Bus, Storage, Object Storage, File Storage, Backup, Disaster Recovery, Feature Flags, Release Management, Deployment, Staging, Production, Agile, Scrum, Product Engineering, UX, UI, Accessibility, Localization, Internationalization, Compliance, Privacy and Governance — is a **review checklist**, not a shopping list.

## Evolution clause

This matrix is intentionally provisional. Repository archaeology, performance evidence, product expansion and production requirements may change statuses. Every material status change should explain the trigger and, where architectural, be recorded through an ADR.
