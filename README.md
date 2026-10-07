# TAB

> Offline-first native iOS expense splitting application with local persistence, optimistic updates, synchronization, and explicit conflict handling.

## Overview

TAB is a native iOS bill-splitting application designed around an offline-first architecture.

Users can create groups, add shared expenses, and calculate balances even without an internet connection.

When connectivity becomes available again, local changes should synchronize with the backend and eventually reach other devices.

The main purpose of TAB is not to build another Splitwise clone.

The project exists to explore:

- Offline-first architecture
- Local databases
- Synchronization
- Optimistic UI
- Conflict resolution
- Distributed state
- Data consistency
- Swift Concurrency
- Networking

## Product Example

```text
Lisbon Trip

Members
├── David
├── Ana
├── Marta
└── Bruno

Expenses
├── Airbnb      €640
├── Dinner      €186.40
└── Taxi         €22.80
```

TAB should determine each participant's net balance and suggest how debts can be settled.

## Core Principle

The application should not depend on the network for normal interaction.

Traditional architecture:

```text
UI
 ↓
API
 ↓
Server
 ↓
Response
 ↓
UI
```

TAB should instead follow an architecture conceptually similar to:

```text
SwiftUI
   ↓
Local Database
   ↓
Sync Engine
   ↓
Backend
```

The local database should act as the primary data source for the interface.

## Tech Stack

Initial technologies to evaluate and use:

- **Language:** Swift
- **UI:** SwiftUI
- **Concurrency:** Swift Concurrency
- **Local Persistence:** SQLite / SwiftData — architectural decision pending
- **Backend:** Supabase
- **Remote Database:** PostgreSQL
- **Authentication:** Supabase Auth
- **Testing:** Swift Testing / XCTest

The synchronization strategy will be evaluated before committing to a specific implementation.

Possible approaches include:

- Custom synchronization layer
- PowerSync
- Supabase Realtime
- Other compatible offline-first solutions

The final decision should be documented and technically justified.

## MVP

The first version should support:

- User registration
- Login
- Create group
- Add participants
- Create expense
- Select payer
- Select participants
- Equal split
- Balance calculation
- Local persistence
- Full basic functionality while offline
- Optimistic updates
- Synchronization after reconnection
- Synchronization status
- Group expense history

## Domain Model

### User

```text
User
├── id
├── name
└── email
```

### Group

```text
Group
├── id
├── name
├── createdBy
└── createdAt
```

### GroupMember

```text
GroupMember
├── id
├── groupId
└── userId
```

### Expense

```text
Expense
├── id
├── groupId
├── paidBy
├── title
├── amount
├── currency
├── createdAt
└── updatedAt
```

### ExpenseSplit

```text
ExpenseSplit
├── id
├── expenseId
├── userId
└── amount
```

The data model may evolve during the database design phase.

## Balance Calculation

Balances should be derived from source data whenever possible.

```text
Expenses
    ↓
Expense Splits
    ↓
Net User Balances
    ↓
Settlement Suggestions
```

Derived balances should not become unnecessary duplicated sources of truth.

## Offline Workflow

Example:

```text
Device goes offline
       ↓
User creates expense
       ↓
Expense stored locally
       ↓
UI updates immediately
       ↓
Change marked as pending
       ↓
Internet connection returns
       ↓
Sync engine processes change
       ↓
Server confirms operation
       ↓
Other devices receive update
```

From the user's perspective, creating an expense offline should feel almost identical to creating one online.

## Synchronization States

Local operations may have states similar to:

```text
Synced
Pending
Failed
Conflict
```

The final model will depend on the synchronization architecture.

## Conflict Resolution

Conflict handling is one of the core engineering challenges.

Example:

```text
David — Offline
Dinner = €100

Ana — Another device
Dinner = €120

       ↓

Both synchronize
```

The system must define deterministic behavior.

Topics to investigate include:

- Last-write-wins
- Server timestamps
- Client timestamps
- Version numbers
- Optimistic concurrency
- Conflict detection
- Merge strategies
- Idempotency
- Server authority

A simple strategy such as last-write-wins may be acceptable for the MVP, but its limitations must be understood and documented.

## Optimistic UI

The expected workflow should be:

```text
User action
    ↓
Local write
    ↓
Immediate UI update
    ↓
Background synchronization
```

The user should not wait for a remote server before seeing their own changes.

## Swift Concurrency

TAB should also be used to explore modern Swift concurrency.

Relevant concepts include:

- `async/await`
- `Task`
- `Actor`
- `Sendable`
- Task cancellation
- Structured concurrency
- Safe access to shared state

Concurrency should be introduced where it solves real synchronization or networking problems rather than simply for demonstration.

## Project Structure

Initial direction:

```text
TAB/
├── App/
├── Features/
│   ├── Authentication/
│   ├── Groups/
│   ├── Expenses/
│   └── Balances/
├── Domain/
├── Persistence/
├── Synchronization/
├── Networking/
├── Models/
├── Services/
└── Tests/
```

## Development Roadmap

### Phase 1 — Product Definition

Define:

- Product scope
- Groups
- Expenses
- Splits
- Balances
- User flows

### Phase 2 — Offline-First Architecture

Define:

- Source of truth
- Local writes
- Sync boundaries
- Repository architecture

### Phase 3 — Relational Data Model

Design:

- Users
- Groups
- Memberships
- Expenses
- Expense splits

### Phase 4 — Local Persistence

Evaluate and choose between:

- SwiftData
- SQLite
- Other justified native persistence strategies

### Phase 5 — Local Application

Build the core application without requiring a backend.

Implement:

- Groups
- Members
- Expenses
- Equal splitting
- Balances

### Phase 6 — Balance Engine

Implement and test balance calculations.

### Phase 7 — Backend & Authentication

Add:

- Supabase
- Authentication
- PostgreSQL

### Phase 8 — Synchronization Protocol

Define:

- Change representation
- Pending operations
- Server acknowledgement
- Error handling
- Versioning

### Phase 9 — Sync Engine

Implement synchronization between local and remote state.

### Phase 10 — Optimistic Updates

Ensure local actions are immediately reflected in the UI.

### Phase 11 — Conflict Resolution

Implement and document deterministic conflict behavior.

### Phase 12 — Multi-Device Testing

Test concurrent changes across multiple devices.

### Phase 13 — Reliability

Test:

- Connectivity loss
- Reconnection
- App restart
- Partial synchronization
- Duplicate operations
- Server failures

### Phase 14 — Testing

Add:

- Domain tests
- Balance tests
- Synchronization tests
- Conflict tests

### Phase 15 — Documentation

Document:

- Offline-first architecture
- Database model
- Synchronization protocol
- Conflict strategy
- Technical trade-offs

### Phase 16 — Release

Prepare:

- Demo
- Screenshots
- Architecture documentation
- Release notes

## Out of Scope

The initial version will not include:

- Payments
- Bank integrations
- Receipt OCR
- Automatic currency conversion
- Chat
- Social networking
- AI features
- Advanced analytics
- Complex split strategies

The initial split strategy will focus on equal splitting.

## Project Philosophy

TAB should not be presented as:

> A Splitwise clone.

Instead, the project should demonstrate:

> An offline-first native iOS application with local persistence, optimistic updates, multi-device synchronization, data consistency, and explicit conflict handling.

## Status

🚧 **In development**

- Phases 1–6 done: product definition, offline-first architecture, data model, SQLite persistence, local app (groups, expenses, equal split) and balance engine. `swift test` runs the domain, repository and balance tests.
- Phase 7 (backend & authentication): Supabase schema, row level security and RPCs in `supabase/` (`supabase/tests/run.sh` validates them on a local Postgres), plus the auth client in `Sources/TABCore/Remote`. See [docs/architecture/backend.md](docs/architecture/backend.md).
- Phase 8 (synchronization protocol): [sync protocol](docs/architecture/sync-protocol.md), [ADR 0002](docs/architecture/adr-0002-sync-approach.md), the local outbox (`pending_operation`, `sync_state`, `conflict`) and its state machine in `Sources/TABCore/Sync`.
- Phase 9 (sync engine): `SyncEngine` (push, pull, recovery, backoff, account binding), `SupabaseBackend` over the RPCs and an in-memory server with fault injection for tests.
- Phase 10 (optimistic updates): local writes show up immediately and request a sync without waiting for it (`SyncScheduler`); a status bar and per-row badges show synced, waiting, failed or conflict without blocking any flow. See [sync protocol](docs/architecture/sync-protocol.md#scheduling-and-sync-status-in-the-ui).
- Phase 11 (conflict resolution): [conflict policy](docs/architecture/conflict-policy.md). Concurrent edits of an expense are detected by version; by default the server's version wins and the losing change stays recorded and can be restored (`ConflictResolver`). There is no UI to review or restore it yet.
- Next: two-device and adverse-network tests.

Backend configuration is injected per build (`SUPABASE_URL`, `SUPABASE_ANON_KEY`); without it the app runs fully offline.
