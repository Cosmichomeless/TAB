# Conflict policy

How TAB behaves when two devices change the same expense at the same time. It builds on the
[sync protocol](sync-protocol.md): detection already exists, this document defines what happens next.

## What counts as a conflict

Only **expenses** are versioned for concurrency. Every `upsert_expense` carries `p_base_version`, the
`expenses.version` the device last saw. The backend answers:

| Situation | Result |
|---|---|
| Same content as the stored row | Acknowledged as a replay, **no conflict**, even if the versions differ. Two devices that make the same change converge without anyone noticing. |
| Different content, `base_version = version` | Applied, `version + 1`. |
| Different content, `base_version <> version` | `40001 version conflict: current version is N` → the operation becomes `conflict` and a row is written to `conflict`. |

Users, groups and memberships are created and never edited concurrently (an `upsert` of a participant is
idempotent on its id), so they cannot conflict today. If an edit for them is added, it has to be added to
this policy as well.

There is no edit-expense UI yet; the only local changes that produce an `upsertExpense` are creating and
deleting (soft delete). The policy is written for edits and is exercised by tests with a server-side hook.

## The policy: the server's order wins, the local change is kept

Default (`ConflictPolicy.remoteWins`):

1. The server's order is the only order all devices agree on, so it decides. **No client clock is used**:
   "last write wins" by device time would let a wrong clock win every conflict.
2. Between the push and the pull of the same cycle the engine fetches the group snapshot
   (`pull_changes(0, …, group_id)`) for each group with an open conflict.
3. In **one local transaction**:
   - the unfinished operations of the entity are retired; the newest one (the user's latest intent) is saved in
     `conflict.local_payload`;
   - the server's copy is stored in `conflict.remote_payload` / `remote_version`;
   - the conflict becomes `resolved` with resolution `remoteWins`;
   - the snapshot is applied with the usual rules (newer versions only), so the entity now shows what the
     server has, parents included.
4. The operations the conflict was holding back in its group are sent in the same cycle.

The result is deterministic: for a given server state and a given set of local operations, every device
ends in the same state, and a second cycle changes nothing (the conflict is resolved, the entity is synced).

### Nothing is lost

The change that lost is not deleted: `conflict` rows stay after they are resolved and contain both versions.
`ConflictResolver.restoreLocal(id)` re-applies the losing change **on top of** the server's version as a new
edit (new `updated_at`, new operation, base version = the server's version). A resolution can be restored once
(`resolution` becomes `restored`).

### Manual mode

`ConflictPolicy.manual` leaves the conflict `open`, holding back its group, and only records the server's copy
(once, not on every cycle). Then `ConflictResolver.keepLocal(id)` rebases the local copy onto the server's
version and requeues the operation, which overwrites the other device's change on purpose (it stays recorded
as `remote_payload`). The app uses the default policy; manual mode is what a future resolution screen needs.

## Trade-offs and limitations

- **Whole-expense granularity.** Versions belong to the expense, not to its fields. Two devices that edit
  different fields of the same expense still conflict, and the server's whole version wins. A field-level
  merge would need per-field versions.
- **Silent for the user.** With `remoteWins` the user's change disappears from the screen without a prompt.
  It is recoverable (`restoreLocal`) but there is **no UI for it yet**; the status bar shows conflicts only
  while one is open, which under the default policy is almost never.
- **Splits go with their expense.** They have no version of their own and are replaced together.
- **Deletes are edits.** A delete that races with an edit is a conflict like any other: the server's version
  wins, so a deletion can lose and be restored.
- **Cost.** The snapshot is the whole group (`since = 0`) because it also brings the parents the expense may
  need. Conflicts are rare, so this is accepted; a per-entity fetch would be an optimization.
- **Only expenses.** A conflict recorded for another entity type is left open and not resolved automatically.
- Not verified against a real Supabase project; tests run against the in-memory backend, which mirrors the
  RPC's rules (see [backend](backend.md)).
