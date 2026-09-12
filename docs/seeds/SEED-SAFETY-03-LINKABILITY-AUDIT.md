# SEED-SAFETY-03 — Operational Linkability Audit

Status: isolated research evidence. No production change is authorized by this document.

Canonical source audited: `0a19605293ef5374a2d832e05eaa40a4572942e2`.

## Core conclusion

A fresh cryptographic `witness_session_id` is **not automatically operationally unlinkable**. It remains unlinkable only if surrounding systems do not export, persist, co-locate, or correlate it with canonical Conversation/participant identifiers, report rows, request IDs, time/activity metadata, logs, backups, or crash material.

The current repository has several useful privacy guards, but it also has durable canonical relationship data. A witness layer can therefore become an enrichment layer for an existing graph even if witness keys and session IDs are independently random.

## Surface matrix

| Surface | Current canonical evidence | Witness rejoin risk | Design implication |
|---|---|---:|---|
| Application Logger | `config/config.exs` disables Ecto query Logger output and the default metadata formatter includes `request_id` plus bounded operational fields, not participant/conversation IDs. | MEDIUM | Do not add witness IDs to Logger metadata or messages. `request_id` can still correlate application activity with provider request logs if the same request is visible in both places. |
| Phoenix channel Logger | `ConversationChannel` uses `log_join: false, log_handle_in: false`. | LOW today, HIGH if regressed | Preserve content/identifier-blind channel logging. Do not encode witness IDs in topics that generic crash/logging paths could emit. |
| Channel crash diagnostic | `ChannelCrashDiagnostic` exists specifically because default OTP channel termination reports can carry topic/socket/payload state. The translator emits failure class and source locations instead. | LOW through this translator; crash-dump risk remains separate | A future witness channel must be covered by the same content/identifier-blind crash discipline. |
| Custom telemetry | `StrangertalksNew.Telemetry` bans participant/conversation/message IDs, payload fields, sockets, IPs and all metadata keys ending `_id`. A field named `witness_session_id` would therefore be stripped by this helper. | LOW through this helper | Do not bypass the helper. This does **not** prove arbitrary Phoenix/APM handlers are safe. |
| Generic Phoenix/APM telemetry | Phoenix runtime events can expose params/socket state to handlers outside the custom sanitizer. | HIGH if a generic exporter is attached | Any APM/OTel/Sentry-style integration requires a separate field-level audit before witness events are exported. |
| Render application logs | Render retains stdout/stderr application logs. | HIGH if application code logs witness IDs, message digests, receipt IDs, or plaintext | Witness code must be log-silent for identifiers/content by default. |
| Render HTTP request logs | On eligible plans Render public request logs contain path/method/status plus a unique `requestID`, also exposed as `Rndr-Id`. | MEDIUM/HIGH | Never put witness session IDs or endpoint identifiers in public URL paths/query strings. Avoid copying provider `Rndr-Id` into witness evidence or durable Safety records unless a concrete requirement exists. |
| Conversation records | `Conversation` durably stores `participant_a_id`, `participant_b_id`, match ID, created/ended timestamps, message counts, first/last-message timestamps and other activity metrics. | **HIGH** | Never use `conversation_id` as `witness_session_id`. Avoid durable witness→Conversation mapping. Even time/count correlation can enrich the existing relationship graph. |
| Reports | `Report` durably links `reporting_participant_id`, `reported_participant_id`, `conversation_id` and report timestamps/context. | **HIGH / intentional Safety join** | A report necessarily crosses into identifiable Safety authority. Keep the witness-to-report join case-bound; do not turn it into a general witness-session directory. |
| Redis / Redix | Repository code search found no Redis/Redix integration on the audited canonical base. | NOT CURRENTLY OBSERVED | If introduced later for witness receipt/session state, it becomes a new correlation and retention authority and needs its own audit. |
| Analytics | Custom telemetry is ID/content-blind, but canonical Conversation rows contain rich activity metrics. | MEDIUM/HIGH through aggregate/timing joins | Do not export witness IDs, roots, receipt digests, or exact session event times into analytics. |
| Database backups | Any witness metadata persisted beside canonical DB records can survive in backups after primary-row deletion, depending on backup policy. | HIGH if mapping exists | Backup retention must be included when claiming witness unlinkability or deletion. |
| Error monitoring | Repository code search found no active Sentry integration on the audited base. Future generic error/APM tooling could capture request/socket/process context. | POTENTIALLY HIGH | No generic error exporter should be considered safe for witness paths until payload/identifier capture is proven off. |
| HTTP/request correlation IDs | Phoenix Logger already carries `request_id`; Render can carry `requestID`/`Rndr-Id`. | MEDIUM/HIGH | Correlation IDs are operationally valuable but can bridge otherwise separate stores. Do not persist shared request IDs into witness commitment or report evidence unless required. |
| BEAM crash dumps | Process heaps/message queues can contain live in-memory state; this concern was accepted in SEED-SAFETY-01. | HIGH under catastrophic dump access | A witness ID, receipt, envelope or plaintext resident in a process can become recoverable from a crash dump even if never inserted in PostgreSQL. Harden crash-dump policy separately. |

## Canonical graph warning

`StrangertalksNew.Conversation` is already a durable participant-pair object. It links two participant IDs and contains multiple timing/activity fields. Therefore the system already possesses a relationship graph independent of the witness design.

A random witness ID can remain cryptographically distinct while still being operationally linkable if any of the following are retained together or can be joined by an operator:

1. `witness_session_id ↔ conversation_id`;
2. `witness_session_id ↔ report_id` where the report directly carries participant and Conversation foreign keys;
3. exact witness timestamps/counts that uniquely match one Conversation row;
4. HTTP request/correlation IDs copied into both witness and application/provider logs;
5. endpoint-key fingerprints retained across sessions;
6. Mode B commitment metadata exported to analytics/logs alongside canonical identifiers.

Therefore future privacy language must always state **unlinkable to which identifier, under which store joins, and under which operator access**.

## Mode A vs Mode B operational linkability

Mode A minimizes new durable witness metadata. Server acceptance receipts may exist client-side without a final centrally retained session record. This does not eliminate ordinary application logs or canonical Conversation metadata, but it minimizes a new server-side join object.

Mode B creates a durable final-session record containing a random witness session ID, final accepted sequence, message count, commitment root, protocol version and server key ID. Even without plaintext or participant IDs, this record can become identifying if joined with canonical Conversation timing/count data or a case-bound Report mapping.

SEED-SAFETY-03 therefore treats Mode B's final record as **pseudonymous session metadata, not anonymous metadata**.

## Operational rules carried forward

- Never set `witness_session_id = conversation_id`.
- Do not place witness identifiers in URL paths or query parameters.
- Do not attach witness IDs to Logger metadata, generic APM spans, analytics events or crash diagnostics.
- Do not copy provider request IDs (`request_id`, `Rndr-Id`) into durable witness evidence by default.
- Keep any report-time mapping from witness evidence to canonical participants inside Safety authority and case scope.
- A global endpoint-key reuse registry is a cross-session linkability store by construction.
- Historical server public-key lookup can be global because server key IDs identify server signing epochs, not users; it must not contain participant/session mappings.
- Backups and log retention count as retention when evaluating unlinkability/deletion claims.

## What this audit does not prove

It does not prove that deployment/operator infrastructure outside the repository contains no additional logs, analytics, support exports, database replicas, or observability integrations. It audits canonical code plus documented provider behavior. Any production admission would require an environment-specific inventory at that time.
