# Offline architecture and trade-offs

This is the entry point to the architecture. It explains how the pieces fit together and why they were chosen,
and links to the detailed documents instead of repeating them:

| Topic | Detail |
| --- | --- |
| Principles and states | [offline-first.md](offline-first.md) |
| Entities and invariants | [data-model.md](data-model.md) |
| Backend, auth, RLS, RPCs | [backend.md](backend.md) |
| Sync protocol and engine | [sync-protocol.md](sync-protocol.md) |
| Conflict rules | [conflict-policy.md](conflict-policy.md) |
| Why SQLite | [adr-0001-persistence.md](adr-0001-persistence.md) |
| Why a custom outbox | [adr-0002-sync-approach.md](adr-0002-sync-approach.md) |

## 1. The shape of the system

```
 SwiftUI views (@Observable models)
        │ read / write
        ▼
 Repositories ──► Database (actor, SQLite, WAL)  ◄── the source of truth for the UI
        │                 │
        │  same transaction: entity change + pending_operation row
        ▼                 ▼
 SyncScheduler ──► SyncEngine (actor) ──► RemoteBackend ──► Supabase (Auth + Postgres RPCs)
                          │                     └─ InMemoryBackend in tests
                          └─ RemoteApplier / ConflictResolver write back into SQLite
```

Four rules hold everything together:

1. **The UI only reads and writes SQLite.** Nothing waits for the network, and the app works with no backend
   configured at all.
2. **A local write and its outbox row commit in one transaction.** There is no state in which a change exists
   without a pending operation, or the reverse.
3. **`SyncEngine` is the only component that talks to the backend**, always through the `RemoteBackend`
   protocol. That is what makes the whole protocol testable without a server.
4. **The server decides order.** `version` and `server_seq` are assigned by the database; client clocks are never
   used to decide who wins.

## 2. Local schema (SQLite)

Defined by numbered migrations in `Sources/TABCore/Persistence/Migrations.swift` and tracked with
`PRAGMA user_version`. A migration that has shipped is never edited; a new one is appended.

| Table | Purpose | Notes |
| --- | --- | --- |
| `users` | People, with or without an account | `version`, `server_seq` |
| `groups` | Expense groups | `currency`, `invite_code`, `version`, `server_seq` |
| `group_members` | Membership | `UNIQUE (group_id, user_id)`, `version`, `server_seq` |
| `expenses` | One row per expense | `amount_minor > 0`, `deleted_at` for soft delete, `version`, `server_seq` |
| `expense_splits` | Each person's share | `amount_minor >= 0`, `UNIQUE (expense_id, user_id)`; no sync columns |
| `pending_operation` | The outbox | `seq`, `kind`, `entity_id`, `group_id`, `payload`, `status`, `attempts`, `next_attempt_at`, `last_error` |
| `sync_state` | Single row | pull `cursor`, bound `account_id`, last pull/push times, last error |
| `conflict` | Changes that lost | `local_payload`, `remote_payload`, `remote_version`, `status`, `resolution` |

Design decisions that matter:

- **UUIDs are generated on the device.** A record can be created offline and keep its identity forever.
- **Money is an integer in minor units.** There is no floating point anywhere near an amount.
- **There is no balance table.** Balances are derived from expenses and splits by `BalanceCalculator`, so they can
  never drift from the data they summarise.
- **Expenses are soft-deleted**, so a deletion is just another versioned change that can be synchronised.
- **Splits belong to their expense.** They are replaced together with it and carry no version of their own.
- `version = 0` and `server_seq = 0` mean "never seen by the server".
- Foreign keys are enforced (`PRAGMA foreign_keys = ON`), and WAL mode lets reads proceed during writes.

### Outbox states

`pending → sending → done`, with `failed` (will retry), `rejected` (permanent, never retried) and `conflict`
(the server holds a newer version). Operations are ordered per group; an operation with no group blocks everything
after it, because later operations may depend on it. A crash while `sending` is recovered at the start of the next
cycle by returning the operation to `pending`.

## 3. Remote schema (Postgres)

Defined in `supabase/migrations/`. It mirrors the local tables with the same column meanings, using `uuid`,
`bigint` and `timestamptz`, plus:

- `users.owner_auth_id` and `users.auth_user_id`: who created a person, and which auth account (if any) is that
  person. This is how a participant who never signed up can later be claimed by a real account.
- `server_seq` and `version` on every synchronised table, assigned by the `bump_version()` trigger.
- `check` constraints that repeat the domain rules (positive amounts, supported currencies, non-empty names).

**Security model.** Row level security is on for every table and only `SELECT` policies exist, based on
`is_group_member` and `shares_group_with`. Direct `INSERT`/`UPDATE`/`DELETE` privileges are revoked. **All writes go
through `SECURITY DEFINER` RPCs**, which validate the caller and are idempotent: replaying the same payload
returns the current row without changing it.

| RPC | Effect |
| --- | --- |
| `claim_user` | Bind the caller's auth account to a person |
| `upsert_participant` | Create or update a person in a group |
| `create_group` | Create a group and its first membership |
| `add_member` / `join_group` | Add a person / join through an invite code |
| `upsert_expense` | Create, edit or delete an expense with its splits, checking `base_version` |
| `pull_changes` | Return every row with `server_seq` above a cursor, filtered by RLS |

## 4. Sync protocol in one page

A cycle runs, in order: **recover interrupted operations → resolve the account → bind the device to it → push →
(resolve conflicts → push again) → pull → record success.**

**Push.** Operations are sent one at a time in `seq` order, each with the `base_version` the device last saw. The
server either applies it and returns the new version, treats it as a replay and returns the current row, or answers
with a conflict (`40001`). Failures are classified:

| Class | Examples | Outcome |
| --- | --- | --- |
| Conflict | `40001` | Operation goes to conflict handling |
| Unauthenticated | `28000`, HTTP 401 | Cycle stops; the session needs attention |
| Permanent | `42501`, `22023`, `23505`, `23503`, `23514`, HTTP 400/403/404/409/422 | `rejected`, never retried |
| Everything else | network errors, 5xx, unexpected errors, `P0002` | `failed`, retried with backoff |

Backoff is `min(300 s, 2 s · 2^(n−1))` with no jitter. Being offline, or the request being cancelled, returns the
operation to `pending` **without consuming an attempt**, because cancellation says nothing about whether the server
applied it.

**Pull.** The cursor lives in `sync_state`. Each pull re-reads from `cursor − 1000` (the overlap) so rows whose
`server_seq` committed slightly out of order are not missed; re-applying a row is harmless because a row is only
applied when its `version` is newer. All pages are fetched **before** anything is written, then applied in one
transaction in dependency order: users → groups → members → expenses. Entities that still have unfinished
operations are skipped so a pull never overwrites an unsent change.

**Accounts.** The first successful cycle records the auth account in `sync_state.account_id`. A different account
afterwards fails with `accountMismatch` instead of mixing two people's data in one database.

**Scheduling.** Local writes request a sync but never wait for it. The UI shows synced, waiting, failed or conflict
per row and in a status bar, and none of those states blocks a flow.

## 5. Conflict rules

A conflict exists only when two changes started from the same version and the server already holds a newer one.
Ordering is by server version, never by timestamps.

- The unit of conflict is the **whole expense**, splits included. Two edits to different fields of the same expense
  still conflict.
- **`.remoteWins` (default).** The server's version is applied locally and the device's change is kept in the
  `conflict` table. `restoreLocal` re-applies it as a new edit on top of the server's version.
- **`.manual`.** The conflict stays open and holds back its group until `keepLocal` rebases the local copy onto the
  server's current version and re-sends it. The app uses the default policy; manual mode is for a future
  resolution screen.
- **The same change on two devices is not a conflict.** Replays are recognised and acknowledged.
- A deletion that races with an edit is a conflict like any other.

Resolution can fail with `ConflictError`: `notFound`, `notOpen`, `notRestorable`, `remoteVersionUnknown`,
`operationGone` or `entityGone`. Each leaves the conflict open and changes nothing.

Everything else (groups, members, users) is idempotent creation, so it cannot conflict in a way that loses data.
The detail is in [conflict-policy.md](conflict-policy.md).

## 6. Decisions and trade-offs

### Persistence: raw SQLite ([ADR 0001](adr-0001-persistence.md))

| Chosen | Gained | Given up |
| --- | --- | --- |
| System SQLite3 behind a `Database` actor | Full control of the schema, transactions and migrations; one transaction for entity + outbox; no dependency; the schema is the same shape as the server's | Hand-written SQL and row mapping; no automatic change observation, so models refresh explicitly |

SwiftData was rejected because its sync hooks and migration behaviour would hide the very things this project is
meant to make explicit. GRDB and Core Data are good, but add a dependency or an object graph for a schema this small.

### Sync: custom outbox over RPCs ([ADR 0002](adr-0002-sync-approach.md))

| Chosen | Gained | Given up |
| --- | --- | --- |
| Local outbox, idempotent RPCs, cursor pull | Every rule is visible and testable; the same engine runs against an in-memory fake; server-side validation stays in one place | We own retry, ordering and recovery code; no live updates between devices |

PowerSync was rejected because it would own the protocol and conflict handling. Supabase Realtime is not used for
the core path; it could be added later as a *hint to pull sooner*, never as the source of data.

### Smaller trade-offs

- **Server-assigned versions instead of CRDTs.** Simple and deterministic, but concurrent edits to one expense
  produce a loser instead of a merge.
- **Whole-expense conflicts.** Easier to explain and to test; coarser than per-field merging.
- **Writes only through RPCs.** Business rules are enforced in one place and replays are safe, at the cost of one
  function per kind of write.
- **Pull with overlap and idempotent apply.** Tolerates out-of-order commits without distributed locking, at the cost
  of re-reading some rows.
- **No jitter in backoff.** Fine for a handful of devices; it would need jitter at scale.

## 7. Known limitations

- `server_seq` is assigned when a row is written, not when its transaction commits. The pull overlap mitigates
  this but does not remove it for a transaction that stays open longer than 1000 sequence values.
- A foreign-key violation while applying a pull fails the whole pull without advancing the cursor, so a malformed
  server state would block synchronisation until fixed.
- A conflict is detected per expense, never per field.
- The deletion timestamp comes from the device clock and the backend compares it exactly to detect a replay. Two
  devices deleting the same expense at different instants therefore register as a conflict rather than a duplicate.
- There is no edit-expense screen yet, and no screen to review or restore a conflict that lost; both are exercised
  through the resolver API and a test hook that edits the server directly.

## 8. What has and has not been verified

**Verified automatically** (`swift test`, 138 tests; `supabase/tests/run.sh`):

- Domain rules, equal splits and balances, including random ledgers that must sum to zero.
- Persistence: repositories, migrations, transactions and rollback.
- The sync engine against the in-memory server: push, pull, recovery, backoff, cancellation, account binding,
  member-id clashes and every `ConflictError`.
- Two devices through concurrent offline edits, connection loss mid-push, failing pulls, restarts, duplicate
  deliveries, server failures and 12 seeded random schedules; devices and server must converge.
- The SQL (RLS, RPCs, idempotency) on a local Postgres.

**Not verified:**

- **No real Supabase project has been used.** GoTrue, PostgREST and JWT handling are covered only by stubs; the SQL
  tests run on Postgres 14 with a stub `auth` schema; `supabase/config.toml` has not been run through the CLI.
- The sync engine, scheduler, conflict policy and resilience tests only ever run against the in-memory fake, so any
  difference between it and the real server would go unnoticed.
- `HTTPTransport` has no tests, and the rollback path of a failing migration is not exercised.
- The UI was only exercised by hand as far as onboarding in the simulator; the status bar, row badges,
  add-expense form, balances and account screens were not.
