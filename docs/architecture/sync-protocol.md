# Sync protocol

How a device and the backend converge. The decision of *which* sync technology to use is in [ADR 0002](adr-0002-sync-approach.md); the backend contract (tables, RPCs, SQLSTATEs) is in [backend.md](backend.md). This document defines the protocol on top of both and is implemented by `Sources/TABCore/Sync`.

## Principles

1. **SQLite is the source of truth for the UI.** The network is never on the UI path.
2. **One write path.** A local write commits the entity change *and* its outbox row in one SQLite transaction. There is no write without an operation and no operation without a write.
3. **Operations are state based.** The payload is the full desired state of the entity (an expense carries all its splits), never a delta. Replaying an operation is harmless and the latest state naturally wins.
4. **Every operation is idempotent.** The entity ID (client-generated UUID v4) is the idempotency key. Replaying an operation the backend already applied returns the existing row without side effects, even if the base version is stale (see [backend.md](backend.md#idempotency)).
5. **The sync engine is the only component that talks to the backend**, through a `RemoteBackend` protocol that an in-memory fake implements in tests.

## Pending operations (outbox)

Table `pending_operation`, filled by `OutboxStore.enqueue` inside the repositories' write transactions.

| Column | Meaning |
|---|---|
| `seq` | Autoincrement position. Defines delivery order. |
| `id` | Operation UUID, for logs and acknowledgements. |
| `kind` | `claimUser`, `upsertParticipant`, `createGroup`, `addMember`, `upsertExpense`. Each maps to one RPC. |
| `entity_id` | The entity the operation changes. |
| `group_id` | Ordering scope. `NULL` blocks every later operation. |
| `payload` | JSON of the full desired state (`*Payload` types). |
| `status` | See the state machine below. |
| `attempts`, `next_attempt_at`, `last_error` | Retry bookkeeping. |

Several operations may exist for one entity (create, then edit, then delete). They are sent in order; the backend ends in the same state as the device.

### Delivery order

An operation is eligible when it is `pending` (or `failed` and past its backoff) **and no earlier operation of the same group is unfinished**. Operations without a group (the account holder's `claimUser`) block everything after them. Consequences:

- A member is always registered before the expense that uses them.
- A group that is backing off does not stop other groups.
- A `rejected` or `conflict` operation holds back the later operations of its group until the user resolves or retries it. This is deliberate: letting dependent operations overtake would produce server errors or a state the user never created.

## Operation states

```text
pending ──send──▶ sending ──ack──▶ done
   ▲                 │
   │ app restart     ├─ transient error ──▶ failed ──(backoff elapsed)──▶ sending
   └─────────────────┤
                     ├─ 401 / 28000 ──────▶ pending   (no attempt consumed)
                     ├─ permanent error ──▶ rejected  (needs attention)
                     └─ 40001 ────────────▶ conflict  (see conflict resolution)
```

| State | Meaning | Leaves the state by |
|---|---|---|
| `pending` | Waiting to be sent. | Being picked by the engine. |
| `sending` | A request is in flight. | Ack, error, or app restart (`recoverInterrupted` → `pending`). |
| `failed` | Transient failure, retried with backoff. | `next_attempt_at` reached. |
| `rejected` | The backend will never accept it as is. | User action (`requeue`) or discarding the change. |
| `conflict` | The entity changed remotely. Details in table `conflict`. | Resolution (issue #13). |
| `done` | Acknowledged. Purged after a grace period. | `purgeDone`. |

### Acknowledgement

An operation is acknowledged when the RPC returns the row. The engine then, in one transaction, writes the returned `version` and `server_seq` to the entity and marks the operation `done`. A replay that returns the already stored row is an acknowledgement too. If the app dies between the response and that transaction, the operation is still `sending`, becomes `pending` after restart and is replayed: idempotency makes that safe.

## Entity status shown in the UI

Not stored on entities; derived from the unfinished operations of the entity (`SyncStatus(operations:)`), taking the most severe:

`synced` < `pending` (`pending`, `sending`) < `failed` (`failed`, `rejected`) < `conflict`.

`OutboxStore.statuses(of:)` and `summary()` expose it for the UI (issue #12).

## Versioning

- The server owns two numbers per row. `version` is 1 on insert and +1 on each update. `server_seq` comes from the global `change_seq` sequence and orders changes for pulling. Both are set by the `bump_version()` trigger.
- The device stores them in `version` and `server_seq` columns (0 = never synced). They are written only from server responses.
- **Optimistic concurrency.** Updating an existing expense sends `p_base_version` = the local `version`. If the server is ahead and the content differs, it fails with `40001` carrying the current version. Creating (`version = 0`) needs no base.
- `updated_at` is informational. **Ordering and conflict detection use versions, never client clocks.**

## Retry

Classification of a failure (`FailureClass.classify`):

| Source | Class | Reaction |
|---|---|---|
| Timeout, no connection, 5xx, 429, unknown error | `retry` | `failed`, backoff, order preserved. |
| `401`, SQLSTATE `28000` | `unauthenticated` | Pause the engine, refresh the session, back to `pending` without consuming an attempt. |
| `40001` | `conflict` | `conflict`, record in table `conflict`. |
| `42501`, `22023`, `23505`, other 4xx | `permanent` | `rejected`. |
| `P0002` (parent row missing) | `retry` | Normally prevented by ordering; retried in case the parent is still in flight. |

Unknown errors are retried on purpose: losing a user's data is worse than trying once more.

Backoff is exponential: `min(300 s, 2 s × 2^(attempts − 1))`, no jitter yet. The engine also tries immediately when connectivity returns, when the app becomes active and after every local write, so backoff only governs repeated failures.

## Pull

1. The device keeps a cursor in `sync_state.cursor` (the highest `server_seq` fully applied).
2. It calls `pull_changes(p_since := cursor - overlap, p_limit, p_group_id)` until a page is shorter than the limit. Rows arrive as `(entity, server_seq, payload)`.
3. Each page is applied in one transaction, then the cursor advances.
4. A change is applied **only if its `version` is newer than the local one**, so applying is idempotent and re-pulling overlapping rows is harmless.
5. **Entities with an unfinished local operation are not overwritten** by a pull. The remote state is kept for conflict resolution if the operation later turns out to conflict.

### Why the overlap

`server_seq` is assigned when the row is written, not when its transaction commits. A transaction with a lower sequence can commit after one with a higher sequence that a client already pulled; a strict `> cursor` would then skip it forever. The client therefore pulls from `cursor − overlap` (initially 1000). Step 4 makes the repeated rows free. This is a mitigation, not a proof: a transaction that stays open longer than `overlap` sequence values could still be missed. At the scale of this app (small groups, short transactions) that is acceptable and documented as a known limitation.

### Snapshot

A device with `cursor = 0` (new install, new member after `join_group`, or switched account) pulls from 0 per group (`p_group_id`) and thereby receives the full snapshot. If the signed-in account differs from `sync_state.account_id`, local sync tables are not reused: the engine refuses to sync until the user chooses to keep or discard local data.

## Push loop

```text
recoverInterrupted()
loop:
  batch = nextBatch()
  if batch is empty: break
  for op in batch:
      markSending(op)
      result = backend.send(op, baseVersion: local version)
      on ack:       apply returned version/server_seq + markDone   (one transaction)
      on failure:   classify → markFailed / markUnauthenticated / markRejected / markConflict
then pull
```

Push first, then pull, so that a pull never overwrites changes the device is about to send.

## Guarantees and non-guarantees

- **No duplicate expenses.** Same operation, same entity ID: the second delivery is a no-op on the server.
- **No lost local change.** A change leaves the outbox only after an acknowledgement.
- **Per-group causal order** for one device. There is no global order across groups.
- **Eventual convergence** while operations can be delivered. Conflicts and rejections stop convergence for the affected group until the user acts; they are never silently discarded.
- **Not guaranteed:** real-time delivery (pull is on demand), end-to-end encryption, protection against a malicious device (the RPCs enforce membership, not business correctness beyond validation).

## Out of scope

Edits to groups and participants (only creation is synchronized for now), membership removal and push notifications of remote changes.
