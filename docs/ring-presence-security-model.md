# StrangerTalks Ring + Hangout Presence Security Model

## Status

This document records the reconstructed current security model for Ring presentation and Hangout presence authority.

Historical PR #248 referred to threat labels B1 through B6. Repository history preserves the known B1 presence-authority problem and B3 Ring audio-energy problem, and preserves the statement that B2/B4/B5/B6 were still open, but it does not preserve trustworthy definitions for those four labels. This model therefore does **not** invent meanings for lost labels. It restates the current attack surface from canonical code and gives each current security invariant an explicit proof.

## Authority boundaries

### Hangout presence

Presence is server/process-owned.

- A browser does not send a presence heartbeat.
- A browser cannot choose or inject a presence lease.
- Every live `HangoutChannel` process registers itself in the duplicate `StrangertalksNew.Hangouts.PresenceRegistry` before durable reconnect is applied.
- Multiple simultaneous channels for the same room/participant are valid and independently registered.
- Channel termination removes only the terminating process registration. Durable membership is marked `DISCONNECTED` only when no other registered live channel remains.
- Explicit `room:leave` is a deliberate durable leave and is not treated as an accidental transport disconnect.
- The Presence Registry and Phoenix Endpoint share a `rest_for_one` supervisor. Registry loss therefore tears down and restarts the transport rather than allowing sockets to survive without presence registrations.
- During that failure-domain teardown, missing Registry authority fails closed to durable disconnect.

### Ring presentation

Ring is presentation-only and consumes authoritative call coordinator state.

- Production wiring calls `ring.update(state)`.
- Ring state may reflect call lifecycle and explicit mute state.
- Ring has no speaking-amplitude input, audio-energy input, network meter input, or persisted meter state.
- Arbitrary second-argument data cannot create Ring state.
- Reaction pulse is an explicit local presentation action, not inferred from audio.

## Reconstructed threats and closure proofs

### R1 — Client-authored presence

**Threat:** a client heartbeat, timer, or supplied identifier claims that a participant is present.

**Closure:** no client presence event exists; join parameters reject client lease injection; the server channel process owns registration.

**Proof:** `hangout_presence_lease_security_test.exs` rejects injected presence lease parameters.

### R2 — Overlapping/replacement channel race

**Threat:** tab A and tab B are both live for one participant; tab A terminates after B joined and falsely marks the participant disconnected.

**Closure:** duplicate process-owned registrations represent all live channels. A termination disconnects durable membership only when the terminating process was the last registered channel.

**Proof:** hostile overlapping-channel test closes the older channel first and requires membership to remain `ACTIVE`, then closes the final channel and requires exactly one durable disconnect.

### R3 — Presence-authority process loss

**Threat:** the Presence Registry restarts while socket/channel processes remain alive, erasing registrations and recreating split-brain presence.

**Closure:** Presence Registry and Phoenix Endpoint share a `rest_for_one` failure domain. Registry loss necessarily restarts the Endpoint/transport. Registry-unavailable teardown fails closed to durable disconnect.

### R4 — Speaking-amplitude / audio-energy inference

**Threat:** Ring or nearby browser code derives speaking state from microphone/peer amplitude, including renamed paths.

**Closure:** the historical `localEnergy` / `peerEnergy` Ring seam and speaking classes were removed. The security contract recursively scans production browser assets for Web Audio analyser APIs, WebRTC audio-level/energy fields, AudioWorklet, and ScriptProcessor amplitude paths.

**Boundary:** adding speaking/amplitude visualization later is a new privacy/security feature and requires explicit review; it is not a refactor of current Ring behavior.

### R5 — New-file / renamed-path CI bypass

**Threat:** production code introduces a new meter or analysis module under a filename not listed by the security workflow, so the gate never runs.

**Closure:** `Ring Authority Security` runs for every PR to `main` and has no `paths:` filter. The JS contract recursively inspects production browser asset files rather than only named owners.

### R6 — Ring state injection or stale presentation authority

**Threat:** an auxiliary payload or inferred signal bypasses the call coordinator and directly changes Ring state.

**Closure:** the public Ring surface is limited to state update, explicit reaction pulse, accessibility text, and destroy. Production wiring passes only coordinator `state`; no second production input exists.

## Non-goals

This model does not claim that all future audio privacy questions are permanently solved. It closes the current shipped attack surface and makes future amplitude/speaking inference an explicit security-review event.

It also does not redefine Hangouts membership policy, skip quorum product law, anonymous identity semantics, or the separate safety/reporting model.

## Admission rule

Ring/presence changes may reach `main` only when:

1. the dedicated Ring Authority Security gate passes on the exact candidate SHA;
2. Hangout/RoomServer/live-call regression suites pass;
3. repository-wide safety/registry/agent gates pass on the exact candidate;
4. the candidate has received an adversarial review specifically attacking overlapping channels, Registry/transport failure coupling, client injection, alternate amplitude mechanisms, and CI scope;
5. no production database mutation or unrelated product redesign is bundled with the admission.
