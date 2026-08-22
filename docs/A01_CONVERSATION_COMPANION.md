# A01 — Conversation Companion

Status: active build on `feature/a01-conversation-companion`.

A01 is the first model-backed StrangerTalks Agent. It is participant-scoped and advisory. It can reason over bounded current-Conversation context and return suggestions, but it has no message-send, queue, Match, Relationship, Block, safety-policy, learning-mutation, or production-configuration authority.

## Invocation

A participant explicitly opens **Ask StrangerTalks** inside the Conversation and requests help. The browser sends the current draft only as part of that explicit request. The server independently authenticates the participant and resolves the Conversation, Match language, membership, safety state, lifecycle state, and bounded recent text context.

Supported modes:

- `start`
- `continue`
- `recover`
- `change_topic`
- `rephrase`
- `simplify`
- `language_help`
- `tone_help`
- `respond`
- `clarify`
- `deescalate`
- `express_feeling`
- `icebreaker`
- `story_prompt`
- `translate_localize`

Supported tones are `natural`, `warm`, `funny`, `direct`, `thoughtful`, `light`, `gentle`, and `confident`.

## Context boundary

The model can receive only the bounded A01 projection:

- authoritative Conversation Language;
- Door when relevant;
- requested mode/tone;
- explicit participant request;
- participant draft supplied during invocation;
- at most 12 recent persisted text messages;
- at most 900 characters per selected message;
- at most 6,000 transcript characters total.

Messages are projected only as `self` or `stranger`. Participant IDs, peer IDs, account identity, safety-review notes, historical readiness fields, analytics fields, private account data, and other Conversations are not included in the provider payload.

## Authority / staleness

Before model invocation, A01 requires:

- authenticated participant membership;
- Conversation status in `PENDING`, `ACTIVE`, or `PAUSED`;
- valid persisted Match language;
- no authoritative BoundaryBlock/CLOSED-Relationship veto.

After model generation, the same authority is re-read. A result is discarded as stale if Conversation status, Match language, safety authority, persisted message count, or latest persisted text sequence changed during generation.

The browser separately protects the participant draft: a suggestion cannot overwrite a draft that changed after the request started.

## Human authorship

A01 never calls `message:send`. A suggestion has no sender, Message ID, sequence, delivery state, or Seen state. **Use in draft** only writes into the local composer after an explicit participant click. The participant must still press the ordinary **Send** control.

## Provider

The production provider is `StrangertalksNew.Companion.OpenAIProvider`, using the OpenAI Responses API through existing `Req` HTTP support. Requests set `store: false`. Generated suggestions pass through the moderation endpoint before being returned.

Default model: `gpt-5.6-luna`.

Runtime configuration:

- `COMPANION_ENABLED=true`
- `OPENAI_API_KEY=<secret>`
- optional `COMPANION_MODEL`
- optional `COMPANION_MODERATION_MODEL`
- optional `COMPANION_TIMEOUT_MS`
- optional `OPENAI_BASE_URL`

No API key is committed to the repository. When the feature is disabled or provider configuration is unavailable, the Companion fails independently and the human Conversation continues normally.

## Privacy

A01 does not create an Agent transcript table or raw-context log. Telemetry contains mode/result/latency only. The provider receives no database or application tools and cannot call back into StrangerTalks runtime authority.

## Safety

Conversation content is treated as untrusted model input, not instructions. The model is told to refuse coercive/manipulative/exploitative requests and not to infer hidden emotional or psychological states. Provider output is schema-bounded, server-validated, and moderated before display.

Deterministic StrangerTalks Block/lifecycle/safety authority remains above A01.
