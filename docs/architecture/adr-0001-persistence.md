# ADR 0001 — Local Persistence: SQLite

- **Status:** Accepted
- **Context:** [Offline-first architecture](offline-first.md), [data model](data-model.md)

## Decision

TAB uses **SQLite** as its local database, accessed through the system `SQLite3` library behind a small Swift wrapper (`Database`, an actor). No third-party dependency is added for persistence.

## Context

The local database is the source of truth for the UI and the home of the operation outbox. The choice needs to support:

- Transactional writes that commit an entity change and its outbox operation atomically.
- Relational queries across groups, members, expenses and splits.
- Explicit, testable schema migrations.
- Inspecting and mutating data from the sync engine, which runs outside the UI.
- Fast in-memory databases for tests.

## Options Compared

| Criterion | SwiftData | SQLite (system library) |
|-----------|-----------|-------------------------|
| **Migrations** | Versioned schemas with lightweight and custom migration stages. Convenient, but behavior is hidden and hard to unit test. | Explicit numbered SQL migrations tracked with `PRAGMA user_version`. Fully visible and testable. |
| **Queries** | `#Predicate` and `FetchDescriptor`. Limited for joins and aggregates; predicate support is restricted. | Full SQL: joins, aggregates, unique constraints, partial indexes. |
| **Transactional writes** | Operates through a `ModelContext`. Atomically saving entities together with outbox rows is possible but implicit. | Explicit `BEGIN`/`COMMIT` around the entity change and the outbox insert. Precisely the guarantee the architecture requires. |
| **Sync needs** | Tracking changes, writing remote changes without creating new local operations, and cursor bookkeeping all fight the framework's change tracking. | Remote changes are applied with plain SQL that bypasses the outbox. The outbox, cursor and conflict tables are ordinary tables. |
| **Concurrency** | `ModelContext` is not `Sendable`; each actor needs its own context and merge behavior. | A single actor owns the connection. Serialized access with no shared mutable state. |
| **Testing** | Needs the framework runtime and a container. | In-memory database (`:memory:`) works in plain `swift test` on macOS. |
| **Mirroring the backend** | Object graph model that does not match the PostgreSQL schema. | Same relational model and constraints as the remote database. |
| **Dependencies / effort** | None, least code for simple CRUD. | None (system library), but more code: statement binding and row decoding. |

## Rationale

TAB exists to explore offline-first architecture, synchronization and consistency. The persistence layer therefore has to expose transactions, constraints and change application explicitly rather than hide them. SQLite gives:

1. A real transaction boundary for "entity change + outbox operation".
2. A schema identical in shape to the PostgreSQL schema, which simplifies the sync protocol.
3. Migrations expressed as SQL that can be tested.
4. In-memory databases for fast, deterministic tests of repositories and the sync engine.

SwiftData would reduce boilerplate for plain CRUD, but the synchronization requirements are the hardest part of this project and are the ones SwiftData makes less transparent.

## Consequences

- We write and maintain a small SQLite wrapper and row-mapping code.
- Migrations are plain SQL files in code, applied in order and versioned with `PRAGMA user_version`.
- Foreign keys are switched on for every connection (`PRAGMA foreign_keys = ON`) and WAL mode is enabled for the on-disk database.
- All database access goes through one actor, so no connection is shared across threads.
- Repositories translate between rows and Domain entities; the rest of the app never sees SQL.
- SwiftUI observation is driven by repository change notifications (an `AsyncStream`) rather than by a framework-provided query.

## Alternatives Not Chosen

- **GRDB.swift:** excellent and would remove the wrapper code, but adds a dependency and hides some of the details this project wants to demonstrate. It remains a candidate if the wrapper becomes costly to maintain.
- **Core Data:** same hidden change-tracking concerns as SwiftData with a heavier API.
- **PowerSync (database + sync):** couples persistence to a sync approach. The synchronization options are evaluated in the synchronization protocol document.

## Revisit When

- The wrapper becomes a significant maintenance cost (consider GRDB).
- A feature needs full-text search or other capabilities better served by an existing library.
