# Team 2 Terminal Truth Re-Audit Plan

Starting authority: `release/prep-2026-08-22` at `585637924ff45933c7b35b0bc27719934907c70e`.

## Goal

Prove that durable Conversation terminal truth cannot be overridden by runtime, channel, client, reconnect, recovery, restart, or stale requests. Preserve prior Team 2 fixes and fix only newly proven Team 2 defects.

## Execution

1. Re-audit existing Team 2 integration history, terminal schema, lifecycle transitions, ConversationServer ordering, RecoverySweeper, reconciliation, Block terminalization, channel join/mutation guards, and terminal client handling.
2. Run the maintained Team 2 exact-SHA workflow against this isolated branch through a draft PR to establish a fresh baseline. Treat the first failing step as the first divergence.
3. Attack terminal paths and races required by the Team 2 charter: End, completion, Block, Report+Block, safety termination, recovery expiry, initialization/recovery failure, abandonment; repeated terminal actions; terminal-vs-message/edit/unsend/reaction/pin/typing/media/view-once/voice/call operations; reconnect/restart/resurrection; participant-busy release; stale and duplicate client events.
4. For each Team 2-owned defect: add a regression that fails on the defective implementation, fix the smallest authoritative boundary, run the focused regression, and re-attack the broader terminal gate.
5. Require real Playwright two-context End and Block proof, focused Elixir and JS terminal suites, full `mix precommit`, `git diff --check`, clean-tree proof, and exact tested SHA recording before any PASS recommendation.
6. Report gaps as unproven instead of weakening tests or substituting database assertions for browser/runtime proof.

## T2-RACE-003 deterministic race closure

The explicit missing races use the same deterministic mechanism: suspend the canonical `ConversationServer`, release two independent public-API callers in a controlled order, verify each `$gen_call` is queued, then resume the server. No arbitrary sleep decides the winner.

Both legitimate orderings are covered for:

- End vs edit
- End vs unsend
- End vs reaction
- End vs pin

For terminal-first ordering, the mutation caller must lose when the server stops after durable End. For mutation-first ordering, that mutation may commit while the Conversation is live, then End must become the one durable terminal truth. Every case re-checks NATURAL_END metadata, dead runtime, rejected resurrection, rejected post-terminal retry, and exactly one terminal client event.

### Remaining terminal race-family classification

- **A — same serialized authority boundary:** text send, typing/ephemeral live state, view-once open, voice-note ACK, call initiation, call credential request, and timeline synchronization. Each ultimately commits through the same ConversationServer mailbox as End; existing post-terminal tests plus the deterministic mailbox ordering proof cover the terminal-first side, while a pre-End commit is legitimately live authority.
- **C — foreign underlying implementation, Team 2 boundary sufficient:** call acceptance. C11 performs an account-wide capacity evaluation before the server call, but live call authority is not created until `commit_call_admission` is accepted by the ConversationServer. Existing pending-call/Block and active-call/End regressions plus post-terminal acceptance rejection retain the Team 2 boundary proof without redesigning Team 4/C11 internals.
- **B — dedicated missing simultaneous regression:** none beyond edit, unsend, reaction, and pin identified above.

## T2-OBS-004 terminal observability matrix

All new Team 2 telemetry metadata is bounded and passes through `StrangertalksNew.Telemetry` sanitization. No Conversation, participant, message, voice-note, call-attempt, token, credential, content, audio, or media identifier is emitted.

| Checkpoint | Signal | Emission boundary | Bounded metadata |
| --- | --- | --- | --- |
| terminal request accepted | `strangertalks_new.terminal.request_accepted` | terminal lifecycle transition enters persistence | `terminal_status`, `lifecycle_event` |
| durable terminal commit | `strangertalks_new.terminal.durable_commit` | successful terminal transition; Block only after outer transaction returns | `terminal_status`, `lifecycle_event` |
| runtime cleanup | `strangertalks_new.terminal.runtime_cleanup` | natural-End observer process DOWN/already stopped; Block cleanup; recovery-race cleanup | `terminal_reason`, `cleanup_path` |
| terminal client notification | `strangertalks_new.terminal.client_notification` | existing `conversation.ended` bus after natural-End channel notification; after Block endpoint broadcast | `terminal_reason`, `notification_path` |
| terminal recovery/rejoin rejected | existing `strangertalks_new.conversation.join.failed` | Conversation channel join rejection | canonical `reason_code` only |
| durable/runtime disagreement | `strangertalks_new.terminal.authority_disagreement` | RecoverySweeper confirms durable live state without runtime, or terminal row races a runtime into existence | `durable_status`, `runtime_status`, `detection_path` |
| terminal persistence failure/rollback | `strangertalks_new.terminal.persistence_failed` | terminal transition write fails | `terminal_status`, `lifecycle_event`, canonical `reason_code` |
| stale terminal action rejected | `strangertalks_new.terminal.stale_action_rejected` | late Block observes an already-durable different terminal ending | `terminal_action`, bounded `canonical_ending` |

`TerminalObservabilityTest` attaches directly to these signals, proves representative End, Block, persistence-failure, RecoverySweeper disagreement, stale-Block, and terminal-rejoin paths, and rejects private/high-cardinality metadata keys.

## Scope boundary

PR #62 is limited to Team 2 terminal authority and its proof surface: Team 2 workflow/evidence, terminal lifecycle instrumentation, RecoverySweeper disagreement visibility, the T2-002 Block terminal-notification boundary, deterministic terminal races, terminal observability tests, connected-End browser proof, terminal channel/idempotency regressions, and the normal-media terminal veto regression. It does not redesign matchmaking, general Conversation UI, media architecture, call architecture, accounts, deployment, or foreign-team feature semantics.
