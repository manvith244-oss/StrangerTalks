# SEED-SAFETY-03 — Witness Operational Boundary Lab

Status: isolated research seed. Canonical `main` is read-only. No merge or production mutation is authorized.

## Base

- Canonical base SHA: `0a19605293ef5374a2d832e05eaa40a4572942e2`
- Seed branch: `seed/safety-03-witness-operational-boundary-2026-09-12`

## Mission

Attack the operational assumptions left unproven by SEED-SAFETY-02 without changing production messaging.

The seed must distinguish cryptographic authenticity from Safety adjudication. No automatic punishment logic belongs here.

## Browser questions

Test current Playwright-supported browser engines with explicit labeling of what they do and do not prove:

- Chrome for Testing / Chromium engine;
- Firefox;
- WebKit engine as a Safari-family approximation only;
- mobile WebKit emulation where useful, explicitly not claimed as native iOS/iPadOS Safari/PWA proof.

Test:

- IndexedDB persistence;
- non-extractable Ed25519 CryptoKey persistence;
- non-extractable AES-GCM evidence-vault key persistence;
- page reload;
- browser-process restart;
- isolated/private-like browser context destruction;
- site-data deletion;
- multiple browser profiles;
- browser storage persistence API observation.

Do not introduce cloud backup.

## Operational failure questions

Model and test:

- server restart during a live witness session;
- restart during Mode B finalization;
- incomplete finalization;
- network loss after message acceptance but before receipt delivery;
- duplicate and delayed receipts;
- crash/reconnect;
- server key rotation and historical public-key lookup;
- evidence degradation when a client has a signed message but lacks an acceptance receipt, final commitment, local evidence, or a required historical verification key.

The verifier must return explicit evidence classifications and `safety_adjudication = NOT_DETERMINED`.

## Mode comparison

Mode A remains the privacy-leading reference: no final transcript-completeness commitment.

Mode B remains optional. `finalized_at` is prohibited unless a concrete requirement is established by this seed. Test whether final-only commitment persistence survives server restart; if it does not, quantify what additional evolving metadata would be required.

## Operational linkability audit

Audit whether hypothetical witness identifiers/receipts could be rejoined to canonical participants through existing architecture surfaces:

- Phoenix/application logs;
- telemetry;
- Render/provider logs;
- crash dumps;
- Conversation records;
- Reports;
- Redis/state stores;
- analytics;
- backups;
- error monitoring;
- request/correlation IDs.

A fresh identifier is not operationally unlinkable merely because it is cryptographically fresh.

## Required output

Return a SEED-SAFETY-03 report with exact base/head SHA, browser and persistence matrices, key-persistence findings, crash/restart behavior, finalization failure states, Mode A/B comparison, accidental-linkage audit, explicit verification degradation states, falsified assumptions, and Council recommendation.
