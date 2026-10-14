# TAB 1.1.0 — first App Store release

Private group expenses that live on your iPhone: no account, no server, no network access. This is the local-only build (`TAB` scheme); the sync engine stays in the repository behind the `TAB-Sync` scheme and is not shipped. See [local-only](../architecture/local-only.md).

The earlier `v1.0.0` tag is the portfolio source tag and was never published; its notes are archived in [release-notes-portfolio-1.0.0.md](release-notes-portfolio-1.0.0.md).

## What is included

- **Groups and people.** A group per trip, flat or night out, in EUR, USD, GBP or JPY. People can be added by name, with or without an email, and do not need the app.
- **Four ways to split.** Equally, by shares, by percentage or by exact amounts. Amounts are integers in minor units, so remainders are assigned deterministically and splits always add up to the total.
- **Safe editing.** Change a title, payer, amount or participants. An unchanged amount and participant set keep an existing unequal split, and the form warns before a change recalculates it.
- **Balances and settling up.** Net balance per person and a minimal set of suggested payments. Settling up opens PayPal or Revolut, or copies a Bizum number or IBAN, then records the payment. TAB never makes or processes a payment, and the payment details stay on the device.
- **Share without a server.** Send a group as a `.tabgroup` file, a QR code or a `tab://` link, or share a who-owes-whom summary as text. Importing can update a group you already have or add it as a copy.
- **Backup and restore.** Export every group to a `.tabbackup` file and restore it, for example on a new iPhone.
- **Delete everything.** "Delete all data" in Settings, behind two confirmations.
- **Languages.** English, Spanish, French, Italian, Portuguese and German. Dates and currency follow the device locale.
- **Privacy.** No accounts, analytics, advertising or third-party SDKs. The app asks for no permission and its privacy manifest declares no collected data. See the [privacy policy](../privacy.md).

## Known limitations

- A shared group is a copy at that moment; later changes are not merged automatically. Importing the same group again offers to replace the expenses in the existing one.
- One currency per group; there is no conversion.
- Amount fields accept `12.5`, `12,50`, `1.234,50`, `1,234.50` and spaces or apostrophes as thousands separators. A lone `.` or `,` before exactly three digits (`1.234`) counts as thousands only when it is the device language's grouping separator; otherwise it is rejected rather than guessed, so `1.234` on an English device is an error, not 1 234.
- iPhone only, portrait only.

## Before submission

These are release gates that need a person or a device, not code:

| Gate | Where | Status |
| --- | --- | --- |
| A week of real use on a physical iPhone, 500+ expenses, force-quit and recovery, Dynamic Type, VoiceOver, dark mode | [device-validation.md](device-validation.md), issue #39 | **Partly done**: the owner reports it works on a real iPhone; the checklist items are not individually recorded |
| Screenshots regenerated for the current UI and localised | [app-store/README.md](app-store/README.md) | **Open** |
| Pages enabled so the privacy and support URLs resolve | repository settings → Pages → `main` / `docs` | **Open** |
| TestFlight beta (20+ testers, 7 days without crashes) and App Review submission | [app-store/README.md](app-store/README.md), issue #49 | **Open** |
| App record, categories, age rating, App Privacy, review notes, build upload and submission (web or Xcode; no MCP can do these) | [app-store/mcp-runbook.md](app-store/mcp-runbook.md) | **Open** |

Record the outcome of the first row in [device-validation.md](device-validation.md) and link it here before the tag is cut.

## Verified

- `scripts/check_localizations.py`: every one of the 161 catalog entries is translated into the five languages, uses the same placeholders as the English text, and matches a string literal in the app sources. `scripts/check_app_store_metadata.py` checks the listing text against App Store Connect's field limits. Both run in CI on every push.
- `swift test` for `TABCore` and `TABSync`, and a `TAB` simulator build, run in CI ([ci.yml](../../.github/workflows/ci.yml)). This workflow was added in the same change as this file and had not run when it was written; check its first result before relying on it.
- The `TAB` target does not compile `App/Sync/` and links only `TABCore`; `Sources/TABCore` and `App/` contain no `URLSession` use. `App/PrivacyInfo.xcprivacy` declares the `UserDefaults` required-reason API (`CA92.1`) and nothing else, and the code uses no other required-reason API.

## Not verified

- The translations were written without a native-speaker review. Check truncation and Dynamic Type in German and French in particular.
- The UI walkthrough (`UITests/WalkthroughUITests.swift`) drives the English UI only.
- Physical iPhone: the owner reports the app works, but the individual checks in [device-validation.md](device-validation.md) (a week of use, 500+ expenses, force-quit recovery, accessibility, other languages) are not recorded.
- No network capture was taken to confirm that the app sends no traffic. The privacy claim rests on the code and the build graph above.
