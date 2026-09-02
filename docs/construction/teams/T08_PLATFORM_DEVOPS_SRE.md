# T08 — Platform, DevOps, DevSecOps & SRE Authority

## Evolution Clause

Deployment providers, cloud architecture and operational tooling may change. The durable requirement is reproducibility, observability, security, recoverability and exact release identity—not loyalty to a cloud brand or orchestration technology.

## Mission

Make StrangerTalks buildable, deployable, observable, recoverable and operationally truthful from development through production.

## Owned authority

- Docker/build/release packaging;
- CI/CD infrastructure;
- staging/production promotion mechanics;
- runtime environment configuration;
- network/ingress/reverse-proxy/DNS topology;
- cloud/deployment platform engineering;
- secrets infrastructure;
- metrics/logs/traces platform;
- backup/restore/disaster recovery;
- capacity/load infrastructure;
- infrastructure-as-code adoption;
- incident/runbook readiness.

## Immediate archaeology inputs

Inspect:

- Dockerfile and release overlays;
- Render/deployment branches and PRs;
- canonical release-gate attempts;
- K2 composed integration workflow;
- PostgreSQL backup/restore scripts;
- production operations docs;
- dependency-security audit history;
- TURN/coturn CI vs actual production topology;
- health/readiness/version endpoint work;
- environment/runtime version drift records.

## Current technology posture

- Docker: ACTIVE NOW.
- GitHub Actions/CI: ACTIVE NOW.
- current deployment provider: establish from live/repo evidence; do not make provider-agnostic claims without proof.
- Kubernetes: NOT JUSTIFIED until container/service topology and HA operations earn it.
- Terraform/IaC: likely trigger-based as infrastructure becomes multi-resource and reproducibility/manual drift becomes costly.
- AWS/Azure/GCP: provider options, not architecture goals.
- NGINX/reverse proxy/load balancer/CDN: document actual topology and introduce only where required.
- OpenTelemetry: useful candidate, especially for extracted services, with strict private-content redaction.

## Required operational truths

- deployed SHA is knowable;
- health and readiness are distinct where dependencies matter;
- migrations are controlled and repeatable;
- secrets are not committed/logged;
- backups are useless until restore is proven;
- rollback path is documented;
- dependency/runtime versions are pinned or deliberately managed;
- CI gates correspond to the exact artifact being promoted;
- user/private content is not casually emitted into observability systems.

## Release evidence

A serious release candidate should prove as relevant:

- exact checkout SHA;
- compile/precommit/tests;
- security/dependency audit;
- production release build;
- migrations against isolated DB;
- readiness;
- container build/provenance;
- backup→isolated restore;
- load/smoke tests;
- clean tree;
- final deployed SHA verification;
- post-deploy health and key user journey.

## Stop conditions

Do not solve application correctness with deployment hacks, bypass failing release gates, or adopt new infrastructure that obscures ownership. Stop when production promotion would rely on an unverified database, backup, ingress, runtime or security assumption.
