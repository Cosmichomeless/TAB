# TAB 0.1.0 (draft; no tag or release published)

First release: an offline-first expense splitting app for iOS 17, with a sync engine that is complete and tested
but not connected to a real backend.

## What is included

- **Groups and participants.** Create a group in a currency (EUR, USD, GBP or JPY), add people with or without an
  email.
- **Expenses.** Record who paid and split the amount equally; amounts are integers in minor units, so there is no
  rounding drift.
- **Expense editing.** Change a title, payer, amount or participants; an unchanged amount and participant set
  preserve an existing unequal split. The form warns before changes that recalculate an equal split.
- **Balances.** Net balance per person and suggested settlements, always derived from the ledger.
- **Fully offline.** Every action reads and writes a local SQLite database. With no backend configured, nothing
  waits for the network.
- **Optimistic sync status.** A status bar and per-row badges show synced, waiting, failed or conflict without
  blocking any flow.
- **Conflict review.** Compare title, amount, payer, shares and deletion state before restoring a losing edit.
- **Sync engine.** Outbox with idempotent operations, cursor-based pull, retry with backoff, crash recovery,
  account binding and deterministic conflict handling. See
  [offline architecture](../architecture/offline-architecture.md).
- **App icon.** A single 1024 px icon in `App/Assets.xcassets`.
- **Supabase schema.** Postgres tables, row level security and RPCs in `supabase/`, validated on a local Postgres.

## Screenshots

See [demo.md](demo.md) and [`screenshots/`](screenshots/).

## Known limitations

- Creating or recalculating an expense uses equal shares; the UI does not edit individual share amounts.
- A conflict is detected per whole expense, never per field.
- `server_seq` is assigned when a row is written rather than when its transaction commits; the pull overlap
  mitigates this.
- Backoff has no jitter.
- The deletion timestamp comes from the device clock and the server compares it exactly, so two devices deleting the
  same expense at different instants register as a conflict.

See [section 7 of the architecture document](../architecture/offline-architecture.md#7-known-limitations) for detail.

## Not verified

This is what has not been checked, stated plainly:

- **No real Supabase project has been used.** GoTrue, PostgREST and JWT handling are exercised only against stubs.
  The SQL tests run on Postgres 14 with a stub `auth` schema, and `supabase/config.toml` has not been run through
  the Supabase CLI.
- **Two devices through a real server has not been demonstrated.** The scenario "create an expense offline,
  reconnect, see it on another device" is demonstrated in tests against an in-memory server only.
- The sync engine, scheduler, conflict policy and resilience tests only run against that in-memory fake, so any
  difference between it and the real server would go unnoticed.
- `HTTPTransport` has no tests, and the rollback path of a failing migration is not exercised.
- The UI walkthrough exercises offline expense entry and editing; its demo conflict banner is not deterministic,
  and no UI test drives a real backend.

## How it was verified

- `swift test`: 149 tests covering domain, persistence, editing, sync, conflicts and resilience.
- `supabase/tests/run.sh`: the SQL, on a local Postgres.
- `docs/release/export-screenshots.sh`: a UI walkthrough on an iPhone 17 Pro simulator.
