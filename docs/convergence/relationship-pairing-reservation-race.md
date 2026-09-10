# Relationship reconnect pairing reservation race

## Why this exists

Canonical anonymous matchmaking already acquires durable `participant_pairing_reservations` before creating a Conversation. Relationship reconnection created the same durable Match/Conversation authority without acquiring those reservations.

The existing hostile race test (`anonymous A+C racing reconnect A+B creates at most one current Conversation`) exposed the missing cross-path atomicity boundary during the full precommit run for PR #256: two new Matches could commit for participant A.

## Closure

Relationship reconnect now acquires the same active participant reservations, in canonical UUID order, inside the same transaction as Match creation and before Conversation creation. The existing partial unique index on active reservations decides the winner across anonymous matchmaking and relationship reconnect without changing Door, safety, or relationship semantics.

A focused regression additionally proves that a successful relationship reconnect owns two active durable reservations for its Match.

No production deployment or migration is performed by this change.
