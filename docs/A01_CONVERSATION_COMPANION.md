# A01 — Conversation Companion

Status: active build on `feature/a01-conversation-companion`.

A01 is the first model-backed StrangerTalks Agent. It is participant-scoped and advisory. It can reason over bounded current-Conversation context and return suggestions, but it has no message-send, queue, Match, Relationship, Block, safety-policy, learning-mutation, or production-configuration authority.

## Invocation

A participant explicitly opens **Ask StrangerTalks** inside the Conversation and requests help. The browser sends the current draft only as part of that explicit request. The server independently authenticates the participant and resolves the Conversation, Match language, membership, safety state, lifecycle state, and bounded recent text context.

The client fails closed when local Conversation authority is ambiguous. It does not guess that the newest locally retained/recovering Conversation is the one the participant intends to ask about.

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
- at most 12 recent live text messages from the authoritative `ConversationServer` runtime;
- at most 900 characters per selected message;
- at most 6,000 transcript characters total;
- the canonical language-qualified Conversation Start starter, only while that starter remains active.

A01 does not invent a second starter authority. When `ConversationServer` still has an active `IcebreakerCatalog` identity, A01 may receive that exact approved identity/text. Once genuine human conversation retires the starter, A01 receives no active canonical starter.

Raw live-message content is not copied into PostgreSQL for A01. The Companion projects from the same temporary in-memory Conversation authority used for delivery and then sends only the bounded projection to the provider.

Messages are projected only as `self` or `stranger`. Participant IDs, peer IDs, account identity, safety-review notes, historical readiness fields, analytics fields, private account data, and other Conversations are not included in the provider payload.

## Authority / staleness

Before model invocation, A01 requires:

- authenticated participant membership;
- Conversation status in `PENDING`, `ACTIVE`, or `PAUSED`;
- valid persisted Match language;
- no authoritative BoundaryBlock/CLOSED-Relationship veto;
- a live authoritative `ConversationServer` runtime from which bounded context can be projected.

After model generation, the same persisted authority is re-read and the live runtime is rechecked. A result is discarded as stale if Conversation status, Match language, safety authority, Conversation runtime epoch, next message sequence, transcript fingerprint, or canonical starter identity changed during generation. A ConversationServer restart therefore invalidates an in-flight result even if the durable Conversation itself remains recoverable.

The browser separately protects the participant draft: a suggestion cannot overwrite a draft that changed after the request started.

## Human authorship and draft recovery

A01 never calls `message:send`. A suggestion has no sender, Message ID, sequence, delivery state, or Seen state. **Use in draft** only writes into the local composer after an explicit participant click. The participant must still press the ordinary **Send** control.

When A01 replaces a draft after explicit **Use in draft**, the original draft remains locally recoverable through **Undo Companion draft**. Undo succeeds only while the current draft still exactly matches the Companion-applied text; if the participant has typed anything newer, Undo fails closed rather than overwriting the newer draft.

## Provider and critic

The production provider is `StrangertalksNew.Companion.OpenAIProvider`, using the OpenAI Responses API through existing `Req` HTTP support. Requests set `store: false`.

A01 uses two bounded model stages for an `assist` result:

1. the generation stage produces structured 2–4 suggestion candidates;
2. a separate critic stage receives only the same bounded public context plus those candidates and may only approve or reject them.

The critic has no tools or StrangerTalks runtime mutation authority. It rejects suggestions that manipulate, invent hidden facts/states, violate boundaries, imply automatic sending, or otherwise fail the A01 communication contract. Critic-approved suggestions then pass through the moderation endpoint before they can be returned.

Default generation model: `gpt-5.6-luna`.

By default the critic uses the same model unless separately configured.

Runtime configuration:

- `COMPANION_ENABLED=true`
- `OPENAI_API_KEY=<secret>`
- optional `COMPANION_MODEL`
- optional `COMPANION_CRITIC_MODEL`
- optional `COMPANION_MODERATION_MODEL`
- optional `COMPANION_TIMEOUT_MS`
- optional `OPENAI_BASE_URL`

No API key is committed to the repository. When the feature is disabled or provider configuration is unavailable, the Companion fails independently and the human Conversation continues normally.

## Privacy

A01 does not create an Agent transcript table or raw-context log. Telemetry contains mode/result/latency only. Both generation and critic provider projections exclude participant IDs, peer IDs, private account data, safety-review notes, and unrelated Conversations. The provider receives no database or application tools and cannot call back into StrangerTalks runtime authority.

## Safety

Conversation content is treated as untrusted model input, not instructions. The model is told to refuse coercive/manipulative/exploitative requests and not to infer hidden emotional or psychological states. Provider output is schema-bounded, server-validated, critic-reviewed, and moderated before display.

Deterministic StrangerTalks Block/lifecycle/safety authority remains above A01.
