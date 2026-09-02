# T05 — Media & WebRTC Authority

## Evolution Clause

Media capability may expand from voice notes/calls and bounded media toward richer Bond media or group audio/video. Expansion must remain consent-aware, privacy-bounded and lifecycle-correct; capability growth is not automatic product approval.

## Mission

Provide reliable media communication without allowing stale permissions, stale signaling, old Conversations or media storage to outlive their authority.

## Owned authority

- WebRTC signaling and client coordinator;
- STUN/TURN/coturn integration;
- call attempt identity/generations;
- microphone/camera permission lifecycle;
- voice note transport/storage behavior;
- normal/ephemeral media technical boundaries;
- media validation;
- media cleanup/revocation;
- future Bond media architecture after product approval.

## Immediate archaeology inputs

Inspect:

- `live_call.mjs` across prep/integration;
- queued-SDP signaling fixes;
- call initiation ABA protection;
- terminal media cleanup;
- view-once/normal media modules;
- voice note controller/storage paths;
- Team 4/6/9/11 media branches and later integration carriers;
- TURN-specific K2 workflow changes.

## Required invariants

- old call attempt callbacks cannot mutate a newer call;
- terminal Conversation ends local media authority;
- permission success arriving late cannot resurrect terminated media;
- signaling is scoped to Conversation + current attempt;
- normal media and ephemeral media use distinct lifetime semantics;
- storage/access URLs cannot bypass participant authority;
- upload validation is server-side;
- media is absent from ordinary logs/telemetry;
- call failure does not corrupt Conversation authority.

## Technology posture

- WebRTC: ACTIVE NOW.
- WebSockets/Phoenix Channels: active signaling transport in coordination with T02.
- TURN/STUN: ACTIVE/REQUIRED where direct connectivity fails; production configuration must be verified rather than inferred from CI.
- object storage/CDN: trigger-based for durable media scale and requires T04 retention/access design.
- native mobile APIs: future trigger when web constraints materially harm media/product quality.

## Required tests

- two isolated browser contexts;
- delayed/out-of-order signaling;
- call A callback after call B begins;
- terminal during permission prompt;
- disconnect/reconnect;
- TURN-relayed path where possible;
- upload type/size/content mismatch;
- stale media reopen after Conversation authority ends;
- object URL/local cache cleanup;
- duplicate accepts/rejects/ends.

## Stop conditions

Stop for product approval before introducing new media classes, broader persistence, location/media metadata exposure, public media, or new relationship prerequisites.
