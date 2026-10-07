# Offline-First Architecture

This document defines the source of truth, the repository boundaries and the ownership of synchronization in TAB. It builds on [the MVP definition](../product/mvp.md).

## Principles

1. **The local database is the source of truth for the UI.** The interface only ever reads from and writes to local storage.
2. **The network is never on the interaction path.** No view, view model or use case awaits a remote response to show the result of a user action.
3. **Synchronization is a background concern with a single owner.** Only the sync engine talks to the backend (authentication aside).
4. **Every local change is recorded as an operation.** Operations are durable, ordered, idempotent and retryable.
5. **Balances are derived.** They are computed from expenses and splits and never persisted as independent truth.

## Layers

```text
┌──────────────────────────────────────────────┐
│ SwiftUI Features (Groups, Expenses, Balances) │
└───────────────────────┬──────────────────────┘
                        │ async calls / observation
┌───────────────────────▼──────────────────────┐
│ Repositories (protocols in Domain)            │
└───────────────────────┬──────────────────────┘
                        │
┌───────────────────────▼──────────────────────┐
│ Local Database (SQLite)                       │
│  • entity tables                              │
│  • operation outbox                           │
│  • sync metadata (cursor, conflicts)          │
└───────────────────────▲──────────────────────┘
                        │ reads/writes
┌───────────────────────┴──────────────────────┐
│ Sync Engine (actor)                           │
└───────────────────────┬──────────────────────┘
                        │ RemoteBackend protocol
┌───────────────────────▼──────────────────────┐
│ Backend (Supabase: Auth, PostgreSQL)          │
└──────────────────────────────────────────────┘
```

Dependencies point downward. The Domain layer (entities, split and balance logic, repository protocols) has no dependency on persistence, networking or UI.

## Reads

- Repositories read exclusively from SQLite.
- Views observe repository output, so changes made locally or applied by the sync engine are reflected without any manual refresh.
- Reads never trigger network calls. A sync may be requested in the background (for example on app launch or when connectivity returns), but the read does not wait for it.

## Writes

A single write path serves every user action:

```text
User action
  → Repository method
  → One SQLite transaction:
       1. apply the change to the entity tables
       2. append an operation to the outbox (status = pending)
  → Return to the caller (the UI updates)
  → Sync engine is notified (non-blocking)
```

The entity change and its outbox operation are committed atomically. A crash can never leave a change without an operation, nor an operation without its change.

## Repository Boundaries

| Repository | Responsibility |
|------------|----------------|
| `GroupRepository` | Create groups, list groups, add and remove members. |
| `ExpenseRepository` | Create, edit, delete and list expenses together with their splits. |
| `SyncStatusRepository` | Expose pending, failed and conflicting operations for the UI. |

Rules:

- Repositories are protocols defined in the Domain layer and implemented in the Persistence layer.
- Repositories never expose SQL, row types or sync internals other than a per-entity `SyncStatus`.
- Repositories never call the backend.
- Balance calculation is a pure Domain function that takes expenses and splits. It is not a repository concern.

## Sync Ownership

The sync engine is the only component allowed to:

- Read pending operations from the outbox and send them to the backend.
- Mark operations as `synced`, `failed` or `conflict`.
- Pull remote changes and apply them to the local tables.
- Store and advance the pull cursor.

The sync engine is an `actor`, so a single synchronization pass runs at a time and its state is not shared unsafely. It talks to the backend through a `RemoteBackend` protocol, which allows a deterministic in-memory backend to be used in tests.

Triggers for a sync pass: app launch, connectivity regained, app returning to the foreground, and after a local write (debounced).

Details of the protocol are defined in the synchronization protocol document.

## Synchronization Status

Each syncable entity exposes a status derived from its operations:

| Status | Meaning |
|--------|---------|
| `synced` | No unconfirmed operation exists for this entity. |
| `pending` | An operation exists and has not been acknowledged yet. |
| `failed` | The last attempt failed and the operation will be retried. |
| `conflict` | The backend rejected the operation because the entity changed remotely. |

The status is data, not a blocking state. A `pending`, `failed` or `conflict` entity remains fully readable and, except while a conflict is unresolved, editable.

## Authentication and Offline Use

Authentication is the only flow that needs the network, and only the first time:

- After a successful login, the session is stored in the Keychain.
- On later launches the app opens from the stored session without a network call.
- The access token is refreshed by the sync engine. An expired token only pauses synchronization; it never blocks the UI.

## Identifiers and Time

- Identifiers are UUIDs generated on the device at creation time, so entities can be created offline and referenced immediately.
- Local timestamps are informational. Ordering and conflict detection rely on versions assigned by the server, not on device clocks.

## Acceptance Check

- Creating groups, members and expenses, reading history and computing balances work in airplane mode.
- No view model or repository awaits a network response.
- The only component that imports the networking layer is the sync engine.
