# Relational Data Model

This document defines the entities, relationships, identifiers and monetary representation shared by the local database and the backend. It builds on [the offline-first architecture](offline-first.md).

## Entity Relationships

```text
User 1───* GroupMember *───1 Group
 │                            │
 │ paidBy                     │ 1
 │                            *
 └──────────*  Expense  *─────┘
                 │ 1
                 *
            ExpenseSplit *───1 User
```

- A **Group** has many **GroupMembers**; a **User** can belong to many groups.
- A group has many **Expenses**. An expense is paid by one user and has one **ExpenseSplit** per participant.
- Every user referenced by an expense (as payer or in a split) must be a member of the expense's group.

## Entities

### User

| Field | Type | Notes |
|-------|------|-------|
| `id` | UUID | Generated on the device. |
| `name` | text | Required. |
| `email` | text, nullable | Null for participants without an account. |
| `createdAt` | timestamp | |

Participants who do not have an account are stored as users with no email. When that person registers later, the placeholder can be linked to the real account.

### Group

| Field | Type | Notes |
|-------|------|-------|
| `id` | UUID | |
| `name` | text | Required. |
| `currency` | text | ISO 4217 code. All expenses of the group use it. |
| `createdBy` | UUID → User | |
| `createdAt` | timestamp | |

### GroupMember

| Field | Type | Notes |
|-------|------|-------|
| `id` | UUID | |
| `groupId` | UUID → Group | |
| `userId` | UUID → User | |
| `createdAt` | timestamp | |

Unique constraint: (`groupId`, `userId`).

### Expense

| Field | Type | Notes |
|-------|------|-------|
| `id` | UUID | |
| `groupId` | UUID → Group | |
| `paidBy` | UUID → User | Must be a member of the group. |
| `title` | text | Required. |
| `amountMinor` | integer (64-bit) | Total in minor units. Must be greater than zero. |
| `currency` | text | ISO 4217. Must equal the group currency. |
| `createdAt` | timestamp | |
| `updatedAt` | timestamp | |
| `deletedAt` | timestamp, nullable | Soft delete, so deletions can synchronize. |

### ExpenseSplit

| Field | Type | Notes |
|-------|------|-------|
| `id` | UUID | |
| `expenseId` | UUID → Expense | |
| `userId` | UUID → User | Must be a member of the expense's group. |
| `amountMinor` | integer (64-bit) | The participant's share in minor units. |

Unique constraint: (`expenseId`, `userId`).

Invariant: the sum of `amountMinor` over an expense's splits equals the expense's `amountMinor`.

## Synchronization Columns

Every entity that synchronizes (all of the above) also carries:

| Field | Where | Notes |
|-------|-------|-------|
| `version` | local and remote | Integer assigned by the server and incremented on every accepted change. `0` means the row has never been accepted by the server. |
| `serverSeq` | remote, mirrored locally | Monotonic change sequence used as the pull cursor. |

Local-only tables hold synchronization state:

| Table | Purpose |
|-------|---------|
| `pending_operation` | Outbox of local changes (see the synchronization protocol). |
| `sync_state` | Pull cursor and last sync information. |
| `conflict` | Local changes that lost a conflict, kept for recovery. |

Synchronization status is derived from the outbox, not stored on each entity.

## Identifiers

- All identifiers are UUIDs (version 4) created by the client. They are stored as lowercase text locally and as `uuid` remotely.
- Client-side identifiers allow offline creation of related entities (a group, its members and its first expense) before any server contact.
- Operation identifiers are also UUIDs and double as idempotency keys.

## Monetary Representation

- Amounts are stored as **integers in minor units** (for example cents). Floating-point types are never used for money.
- The number of minor-unit digits comes from the currency (EUR: 2, JPY: 0). For the MVP the supported currencies and their exponents are defined in the Domain layer.
- A single currency applies per group, so balances never mix currencies and no conversion is needed.
- Display formatting is a presentation concern; the stored value is always the integer.

## Preventing Duplicated Balance Truth

- There is **no balance table or column**. Net balances are computed on demand from `Expense` and `ExpenseSplit`.
- Expense splits are the only record of who owes what, and they belong to the expense aggregate: they have no sync metadata of their own and travel with their expense (see `backend.md`). The expense `amountMinor` must always equal the sum of its splits, enforced by the Domain layer before writing and checked by tests.
- Settlement suggestions are derived from balances and never stored.
- Soft-deleted expenses are excluded from every derivation.

Computing balances on demand is cheap at the scale of a group, so no cache is justified. If one is ever introduced it must be disposable and rebuildable from the source rows.

## Referential Integrity

- Foreign keys are enforced in SQLite (`PRAGMA foreign_keys = ON`) and in PostgreSQL.
- Deleting a group, user or membership is out of scope for the MVP. Expenses are soft-deleted.
- Remote constraints mirror the local ones so that a state valid on one side is valid on the other.
