# Local-only build

TAB 1.0 ships without accounts, sync or any network access. The sync design in this folder still exists and is tested; it is kept out of the app that goes to the App Store.

## What ships

| Target | Links | Compiles | Network |
| --- | --- | --- | --- |
| `TAB` (App Store) | `TABCore` | everything in `App/` except `App/Sync/` | none |
| `TAB-Sync` (not shipped) | `TABCore`, `TABSync` | all of `App/`, with the `SYNC` flag | Supabase, when configured |

## Module boundary

- `TABCore`: domain, SQLite database, repositories, balances. It also keeps the `pending_operation` table and `Outbox.enqueue`, so repositories write the operation in the same transaction as the data. Without sync the table simply stays unused.
- `TABSync`: `SyncEngine`, `SyncScheduler`, `ConflictResolver`, Supabase client, auth and session store. Depends on `TABCore`.
- `App/Sync/`: the account screen, status bar, sync badges, conflict views and `AppModel+Sync`. Excluded from the `TAB` target and wrapped in `#if SYNC` as a second guard. The few places in shared views that touch sync (badges, banner, account button, the text of the delete dialog) are also behind `#if SYNC`.

## Verification

- `swift test`: 106 tests in `TABSyncTests` and 43 in `TABCoreTests`, 149 in total, unchanged by the split.
- Both schemes build: `xcodebuild -scheme TAB` and `xcodebuild -scheme TAB-Sync`.
- The `TAB` binary and its `Info.plist` contain no `Supabase`, `SyncEngine`, `TABSync` or `NWPathMonitor` strings (checked with `strings`).
- The UI walkthrough asserts that there is no Account button and no sync status in the local app.

## Turning sync back on

Ship the `TAB-Sync` scheme, or move `App/Sync/` into the `TAB` target sources and add the `TABSync` dependency. Privacy policy, App Store privacy labels and the data-deletion story would need to change first.
