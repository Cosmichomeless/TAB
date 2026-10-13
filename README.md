<div align="center">

# TAB

**Split group expenses offline and see exactly what each person owes.**

![Status: MVP, no public backend](https://img.shields.io/badge/status-MVP%20local%20demo-yellow) ![SwiftUI](https://img.shields.io/badge/SwiftUI-iOS-teal) ![License: MIT](https://img.shields.io/badge/license-MIT-green)

[Try it](#try-it) · [Screenshots](#screenshots) · [Architecture](#architecture) · [Documentation](#documentation)

</div>

[![TAB app icon beside real group and trip screenshots](docs/screenshots/00-showcase.png)](#screenshots)

TAB is a native iOS expense-sharing app whose local SQLite database is the source of truth. Groups, participants, expenses, balances and settlements work without a connection; the data never leaves the device: there are no accounts and no server. A sync engine (outbox, versioned operations, conflict review) exists in its own module and in a separate `TAB-Sync` build target, but it is not part of the app that ships; see [local-only](docs/architecture/local-only.md).

## What it includes

- **Offline-first groups:** create a group, add people and record expenses without waiting for a server.
- **Exact balances:** amounts use integer minor units; equal splits distribute remainders deterministically.
- **Safe editing:** edit a shared expense while preserving an existing unequal split unless the amount or participants change.
- **No account, no network:** the shipping app has no sign-in, no analytics and no network code; it asks for no permission.
- **Sync (separate build):** the `TAB-Sync` target adds sync states and conflict review on top of the same local database.

## Try it

On a Mac with Xcode and [XcodeGen](https://github.com/yonaskolb/XcodeGen), run this from the repository root, then choose the TAB scheme and an iPhone simulator in Xcode. The `TAB` scheme is the local app and needs no credentials; the `TAB-Sync` scheme compiles the sync UI with the `SYNC` flag and reads `SUPABASE_URL` and `SUPABASE_ANON_KEY` from the build settings.

    xcodegen generate && open TAB.xcodeproj

The Xcode project is generated locally from [project.yml](project.yml) and is not committed. For a reproducible UI walkthrough, see [the demo guide](docs/release/demo.md); its screenshot script resets data in the selected simulator.

## Screenshots

The cover pairs the real app icon with crops of the screens below. Captured with the Debug UI walkthrough on an iPhone 17e simulator using seeded sample groups. To regenerate the raw walkthrough images, run [docs/release/export-screenshots.sh](docs/release/export-screenshots.sh) with a suitable simulator; the four PNGs below are smaller, curated copies for GitHub. Select an image to view it at full size. After updating the committed PNGs, rebuild the cover with Pillow:

    python3 docs/screenshots/build-showcase.py

| **Welcome** | **Groups and balances** |
| --- | --- |
| [![Teal TAB onboarding with name entry](docs/screenshots/01-onboarding.png)](docs/screenshots/01-onboarding.png) | [![Demo groups with balances and sync states](docs/screenshots/02-groups.png)](docs/screenshots/02-groups.png) |
| **Group detail** | **Edit an expense** |
| [![Lisbon trip expenses and conflict notice](docs/screenshots/03-group-detail.png)](docs/screenshots/03-group-detail.png) | [![Expense editing with payer and split participants](docs/screenshots/04-edit-expense.png)](docs/screenshots/04-edit-expense.png) |

## Architecture

```mermaid
flowchart LR
    UI[SwiftUI] -->|Local reads and writes| DB[SQLite]
    DB -.->|TAB-Sync only| Outbox[Outbox]
    Outbox -.->|Push and pull| Engine[TABSync engine]
    Engine -.->|Optional authenticated RPCs| API[Supabase schema]
```

The solid path is the shipping app (`TAB`, which links only `TABCore`). The dashed path exists only in `TAB-Sync`.

- **UI and storage:** local repositories provide immediate results, including while offline.
- **Balance engine and outbox:** balances are derived from expenses; changes are queued transactionally.
- **Sync boundary:** `TABSync` is a separate SwiftPM library that depends on `TABCore`, never the other way round. The local app does not link it, so no sync or network code ends up in the shipping binary.

## Design decisions

| Decision | Why | Cost |
| --- | --- | --- |
| **SQLite as source of truth instead of server-first requests** | Groups and balances respond offline. | Sync and recovery logic must be owned by the app. |
| **Integer minor units instead of floating point** | Splits and balances stay exact. | Currency formatting and parsing need explicit rules. |
| **Equal splits instead of arbitrary split editing** | Remainders are deterministic across devices. | Changing an amount or participant set replaces a custom split with an equal one. |
| **Versioned outbox instead of last-write-wins silently** | A losing edit can be inspected and restored. | More state and conflict UI to maintain. |

## Known limitations

- The shipping app is local only; sync is not offered to users. No Supabase project is provisioned. Multi-device convergence is verified against an in-memory server, not a live deployment.
- Equal splitting is the creation flow; the editor preserves a pre-existing unequal split only while amount and participants stay the same.
- Payments, bank connections, automatic currency conversion and receipt OCR are out of scope.
- The source is tagged v1.0.0 for the portfolio; no GitHub Release or App Store build has been published. The [release notes](docs/release/release-notes.md) distinguish what was tested from what was not.

## Quality

- 149 Swift package tests pass across domain, persistence, balances, editing and sync; this is not a claim of production backend coverage.
- UI walkthroughs exercise onboarding, offline expense entry and editing on an iPhone simulator. The conflict banner depends on the demo state and is not a deterministic screenshot assertion.
- The offline-to-online two-device scenario runs against an in-memory backend. No hosted CI is claimed here.

## Documentation

| Document | Contents |
| --- | --- |
| [Product MVP](docs/product/mvp.md) | User flows and scope. |
| [Offline architecture](docs/architecture/offline-architecture.md) | Storage, sync and trade-offs. |
| [Data model](docs/architecture/data-model.md) | Users, expenses, splits and balances. |
| [Local only](docs/architecture/local-only.md) | What ships, what is behind `SYNC`, and how it is verified. |
| [Sync protocol](docs/architecture/sync-protocol.md) | Outbox, retries and convergence (`TABSync`). |
| [Conflict policy](docs/architecture/conflict-policy.md) | Resolution and restoration. |
| [Demo](docs/release/demo.md) · [Release notes](docs/release/release-notes.md) | Screenshots and validation boundaries. |

## Repository layout

    App/               SwiftUI screens and icon-driven theme
    Sources/TABCore/   Domain, SQLite repositories, balances
    Sources/TABSync/   Sync engine, auth and Supabase client (TAB-Sync build only)
    Tests/             Domain, persistence and sync tests
    UITests/           Simulator walkthroughs
    supabase/          Schema and RPCs (not deployed for this demo)
    docs/              Architecture decisions, demo and release evidence

## Distribution and license

No production backend or App Store version is deployed. Credentials are supplied per build if a developer configures their own backend. Licensed under [MIT](LICENSE).
