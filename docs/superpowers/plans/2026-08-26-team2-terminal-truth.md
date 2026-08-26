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
