# App Store Connect handoff

Everything the App Store Connect side of the release needs, collected from the repository so nothing has to be invented there. Issue #49 tracks the work; #47 (compliance) and #48 (localisation) feed it.

Listing text for each language lives next to this file (`en-US.md`, `es-ES.md`, `fr-FR.md`, `it.md`, `pt-PT.md`, `de-DE.md`), one `##` section per App Store Connect field, and `scripts/check_app_store_metadata.py` checks the character limits. Use `pt-PT` text for `pt-BR` as well, and `es-ES` for `es-MX`, unless a native speaker adapts it.

## App record

| Field | Value |
| --- | --- |
| Name | `TAB: Split Expenses` (en-US); see each locale file. App Store names are unique, so if it is taken use `TAB: Shared Expenses` or similar and keep the `TAB: …` pattern |
| Bundle ID | `com.cosmichomeless.TAB` (the `TAB` scheme; `com.cosmichomeless.TAB.sync` is the unshipped sync build and must not be uploaded) |
| SKU | `tab-ios` (free choice, never shown) |
| Primary language | English (U.S.). Spanish (Spain), French (France), Italian, Portuguese (Portugal) and German are added as localisations |
| Version | `1.1.0` (`MARKETING_VERSION` in `project.yml`; `v1.0.0` is the portfolio source tag) |
| Build number | `CURRENT_PROJECT_VERSION` is `1`; every upload needs a higher one, so pass `CURRENT_PROJECT_VERSION=<n>` when archiving |
| Platform | iPhone only (`TARGETED_DEVICE_FAMILY = 1`), iOS 17.0 or later, portrait |
| Category | Primary: Finance. Secondary: Travel |
| Price | Free, no in-app purchases (assumption: confirm) |
| Copyright | `2026 David Rodríguez` (the `LICENSE` holder) |

## URLs

Enable GitHub Pages first (repository Settings → Pages → Deploy from a branch → `main`, folder `/docs`). `docs/_config.yml`, the front matter in `docs/privacy.md` and `docs/support.md` do the rest.

| Field | URL |
| --- | --- |
| Privacy Policy URL | `https://cosmichomeless.github.io/TAB/privacy/` |
| Support URL | `https://cosmichomeless.github.io/TAB/support/` |
| Marketing URL (optional) | `https://github.com/Cosmichomeless/TAB` |

The same two URLs are linked from Settings → About inside the app. Check that both resolve before submitting.

## App Privacy

- **Data collection:** *Data Not Collected*. The app has no accounts, analytics, advertising or third-party SDK and makes no network request.
- **Tracking:** none. `App/PrivacyInfo.xcprivacy` declares `NSPrivacyTracking = false`, no tracking domains, no collected data types, and the `UserDefaults` required-reason API (`CA92.1`).
- **Permissions:** none requested (no camera, photos, location, contacts or notifications). Scanning a QR code uses the system camera app, which opens a `tab://` link.

## Age rating

Answer *None* / *No* to every content and capability question (no violence, sexual content, gambling, medical content, unrestricted web access, user-generated content, messaging or advertising). The expected result is 4+. Settle-up shortcuts open PayPal or Revolut but TAB itself does not process payments.

## Compliance

- **Export compliance:** `ITSAppUsesNonExemptEncryption = false` is set in the Info.plist (the app uses no encryption of its own), so no per-build question appears.
- **EU Digital Services Act:** App Store Connect asks whether the developer is a *trader*. That is a legal statement about the owner of the account and must be declared by them. If *trader*, the name, address, phone and email entered are shown on the EU product page.
- **Content rights:** the app contains no third-party content. PayPal, Revolut and Bizum are named only as destinations the user chooses; no logos are bundled.
- **Sign in with Apple:** not required, because there is no sign-in at all.

## App Review notes

Paste into *App Review Information → Notes*; no demo account is needed:

> TAB has no accounts and no network access, so there is nothing to sign in to. All data is stored on the device.
>
> To try it: enter any name on the first screen, tap "New group", name it and tap "Create", open it, tap the add-participant button to add a second person, then tap "Add expense", enter a title and an amount, and "Save". The balances and a suggested payment appear on the group screen; tap the suggested payment to open "Settle up".
>
> "Settle up" only opens PayPal or Revolut, or copies a Bizum number or IBAN to the clipboard. TAB never makes, processes or holds a payment. Sharing a group uses the system share sheet to send a `.tabgroup` file or a `tab://` link; nothing is uploaded. Settings contains a backup/restore and a "Delete all data" option, and links to the privacy policy and support page.

## Screenshots

Required sizes per issue #49: iPhone 6.9" (1320 × 2868) and 6.5" (1284 × 2778). Six screens per language, with these captions (each locale file has them translated):

1. No account. Just your name. (onboarding)
2. Works offline. (group list)
3. Split equally, by shares, by % or exact amounts. (new expense, Exact selected)
4. See exactly who owes whom. (group detail with balances)
5. Settle up with PayPal, Revolut, Bizum or IBAN. (settle up)
6. Your data stays on your iPhone. (settings)

The committed PNGs in `docs/release/screenshots/` and `docs/screenshots/` were captured before the local-only split, new split methods and settle-up, and the README ones still show sync states; regenerate them. This needs a Mac:

```sh
xcodegen generate
xcodebuild build -project TAB.xcodeproj -scheme TAB \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro Max' -derivedDataPath build
xcrun simctl boot "iPhone 17 Pro Max"
xcrun simctl install booted build/Build/Products/Debug-iphonesimulator/TAB.app
xcrun simctl status_bar booted override --time 9:41 --batteryState charged --batteryLevel 100 --cellularBars 4 --wifiBars 3
# One language at a time: -demoData seeds the "Lisbon trip" group (Debug builds only; its text stays in English).
xcrun simctl launch booted com.cosmichomeless.TAB -resetData -demoData -AppleLanguages "(es)" -AppleLocale es_ES
xcrun simctl io booted screenshot es-01-groups.png
```

Navigate to each screen by hand and repeat `screenshot`. `UITests/WalkthroughUITests.swift` drives the English UI and is not language-independent, so it cannot produce the localised sets as is.

## Order of work

1. Merge this branch; confirm the first CI run is green.
2. Enable GitHub Pages and check the two URLs.
3. Complete [device-validation.md](../device-validation.md) on a real iPhone (issue #39). Fix whatever it finds.
4. Create the app record, add the six localisations from the files here, fill App Privacy, age rating, pricing and the EU trader declaration.
5. Regenerate and upload screenshots for every language.
6. Archive and upload a build (Release, with a team and an incremented build number):
   ```sh
   xcodebuild archive -project TAB.xcodeproj -scheme TAB -configuration Release \
     -destination 'generic/platform=iOS' -archivePath build/TAB.xcarchive \
     DEVELOPMENT_TEAM=<team id> CURRENT_PROJECT_VERSION=<n>
   xcodebuild -exportArchive -archivePath build/TAB.xcarchive -exportOptionsPlist ExportOptions.plist -exportPath build/export
   ```
   (`ExportOptions.plist` with `method = app-store-connect` is not committed because it carries the team id.)
7. TestFlight: internal testing first, then an external group of at least 20 testers with the built-in feedback form. Exit criteria from #49: no crashes for 7 days and an average rating of 4/5 or more. Beta goal from #37: 50 groups created with 3 or more participants.
8. Keyword research (`keyword_insights`, `competitor_snapshot`) for 30–50 candidates; the keywords in the locale files are a starting point, not researched. Do not use competitor names in keywords, which App Review rejects.
9. Submit for review, then tag the release (`v1.1.0`, not `v1.0.0`, which already exists) and publish a GitHub Release.
10. Launch plan (Product Hunt, Reddit, travel communities) after approval.

## Open decisions for the owner

- Primary language (English vs Spanish) and the final app name once availability is known.
- Price and the EU trader declaration.
- Whether native speakers review the translations before submission.
