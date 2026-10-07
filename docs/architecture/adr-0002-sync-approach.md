# ADR 0002 — Synchronization: custom outbox over Supabase

- **Status:** Accepted
- **Context:** [Offline-first architecture](offline-first.md), [sync protocol](sync-protocol.md), [backend](backend.md), [ADR 0001](adr-0001-persistence.md)

## Decision

TAB synchronizes with a **custom outbox/pull protocol** over the Supabase backend (Postgres RPCs), implemented in Swift in `TABCore`. No sync framework and no Realtime subscription is used in the first version.

## Context

The product needs: writes that never block on the network, delivery after reconnection without duplicates, visible sync state per entity, and a defensible conflict policy. The data is small and highly structured (groups, expenses with splits), with a few devices per group and rare concurrent edits of the same expense.

## Options Compared

### 1. Custom outbox + pull (chosen)

- **For:** the protocol is small, fully testable with an in-memory backend, and every behaviour the issues ask for (acknowledgements, retry, `failed`/`conflict` states, idempotency) is explicit code and explicit documentation. Works with the existing SQLite layer and with plain Postgres. No extra service or dependency. The conflict policy is ours to define.
- **Against:** we own the hard parts: ordering, cursor correctness (see the `server_seq` overlap), retries, edge cases. More code to maintain and to get wrong than adopting a framework.

### 2. PowerSync

- **For:** mature offline sync on SQLite with a streaming service, sync rules and a client SDK; solves cursoring and partial replication for us.
- **Against:** adds a hosted or self-hosted service plus an SDK that owns the local database schema and write path, which collides with our SQLite wrapper and the rule "one write path: entity change plus outbox row in one transaction". Conflict handling is still the app's job, so the main hard part is not removed. Another vendor and moving part for a small data model. Hides the sync behaviour the project wants to design and document.

### 3. Supabase Realtime (as the sync mechanism)

- **For:** simple live updates from Postgres changes; trivial to subscribe to.
- **Against:** it is a **delivery** channel, not a sync protocol. It gives no offline queue, no ordering or catch-up after being disconnected, no acknowledgements and no conflict handling. Events missed while offline are not replayed, so a pull-by-cursor is needed anyway.
- **Verdict:** not a replacement, but a good later **complement**: a Realtime event can trigger a pull so other devices see changes quickly. It would not change the protocol.

## Consequences

- The backend exposes idempotent RPCs with versions and `pull_changes` (implemented in issue #9).
- The sync engine is an actor behind a `RemoteBackend` protocol (issue #11); tests use an in-memory fake, which makes two-device and adverse-network tests possible without a server (issues #14, #15).
- Known risk: `server_seq` is assigned at write, not commit time. Mitigated by pulling with an overlap and applying changes idempotently ([sync protocol](sync-protocol.md#why-the-overlap)).
- If the product later needs many devices per user, large datasets or partial replication, PowerSync becomes the natural migration path. The state-based, idempotent operations and the versioned rows keep that door open.
