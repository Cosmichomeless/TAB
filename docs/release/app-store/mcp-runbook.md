# Runbook for the App Store Connect MCP

For [SardorbekR/appstore-connect-mcp](https://github.com/SardorbekR/appstore-connect-mcp) (`asc-mcp`, 1.1.0 at the time of writing). It is a thin wrapper over Apple's App Store Connect API, so it can edit listing text, upload screenshots, read builds and manage testers, but several release steps are not exposed by it or by Apple's API at all. This file says which is which. Source of the listing text: the `<locale>.md` files next to this one; shared facts (URLs, review notes, privacy answers) are in [README.md](README.md).

## Setup (manual, once)

1. App Store Connect → Users and Access → Integrations → App Store Connect API: create a key with the **App Manager** role (Admin only if you also need to manage users). Download the `.p8` once.
2. Give the MCP `APP_STORE_CONNECT_KEY_ID`, `APP_STORE_CONNECT_ISSUER_ID` and `APP_STORE_CONNECT_P8_PATH` (or `..._P8_CONTENT`) in the environment of the client that runs it. Never put the key, key id or issuer id in this repository, in a prompt or in an issue; `chmod 600` the file.
3. Ask the MCP for `list_apps`. If it returns nothing yet, that is expected before step 2 below.

## Steps

| # | Who | What |
| --- | --- | --- |
| 1 | MCP | `create_bundle_id` with identifier `com.cosmichomeless.TAB`, name `TAB`, platform `IOS` (skip if `list_bundle_ids` already has it). Do **not** register `com.cosmichomeless.TAB.sync`. |
| 2 | **You, in the web** | Create the app record (My Apps → New App): iOS, name from `en-US.md`, primary language English (U.S.), bundle ID from step 1, SKU `tab-ios`. Apple's API has no endpoint to create an app, so no MCP can do this. |
| 3 | **You, in the web** | The new record comes with an editable version `1.0`. The MCP has no tool to change a version string and cannot create a second editable version, so edit it to `1.1.0` in the web UI so it matches the binary (`MARKETING_VERSION`), or tell Claude to set the app to `1.0.0` instead. |
| 4 | MCP | `list_apps` → `appId`; `list_app_versions` → `versionId`; `list_version_localizations` → the en-US `localizationId`. |
| 5 | MCP | `update_version_localization` for en-US with `description`, `keywords`, `promotionalText` from `en-US.md`, plus `supportUrl` and `marketingUrl` from README. Skip `whatsNew` on a first version: App Store Connect normally does not accept it, so expect an error if you send it. |
| 6 | MCP | `create_version_localization` for `es-ES`, `fr-FR`, `it`, `pt-PT`, `de-DE`, with the same fields from each file and the same two URLs. |
| 7 | MCP | `list_app_infos` → `appInfoId`; `list_app_info_localizations`. `update_app_info_localization` sets `name`, `subtitle` and `privacyPolicyUrl` (`https://cosmichomeless.github.io/TAB/privacy/`) for each locale that is listed. The MCP cannot create an app-info localization: if the five other locales are missing from the list, add the languages in the web UI (App Information → Localizable Information) and run this step again. |
| 8 | **You, in the web** | Category (Finance primary, Travel secondary): `list_app_categories` only reads them. Age rating questionnaire, App Privacy (*Data Not Collected*), content rights, DSA trader declaration, App Review contact and the notes from README, copyright if it was not set in step 4. None of these has a tool in this MCP. |
| 9 | MCP | Price: `list_app_price_points` (territory `USA`) to find the free (0.00) price point, then `set_app_prices` with `baseTerritory` `USA`. Check with `get_app_price_schedule` and `get_app_availability`; availability is read-only here, so set territories in the web UI if needed. |
| 10 | **You, on a Mac** | Upload the build with `xcodebuild archive` / `-exportArchive` (see README) or Xcode Organizer or Transporter. The MCP only reads builds. |
| 11 | MCP | `list_builds` until the build shows as processed (and `get_build` for its details). |
| 12 | **You, on a Mac, then MCP** | Capture the screenshots (README). `list_screenshot_sets` for each locale shows the sets that exist (`APP_IPHONE_69`, `APP_IPHONE_65`); `upload_screenshot` fills a set with `fileName`, `fileSize` (bytes, must match the file) and an absolute `filePath`, in caption order. The MCP cannot create a set: if a display type is missing, upload its first screenshot in the web UI and let the MCP do the rest. |
| 13 | **You, in the web** | Attach the build to the version, answer the export-compliance question if it appears (the plist already says no encryption), and **Add for Review / Submit**. This MCP has no tool to select a build or submit a version, so submission stays manual. |
| 14 | **You, in the web, then MCP** | TestFlight: create the internal and external groups (the MCP cannot create groups), submit the external build for Beta App Review, then `list_beta_groups` and `add_beta_tester` / `list_beta_testers` / `remove_beta_tester` for the 20+ testers. |
| 15 | MCP | After release: `get_app_perf_metrics`, `list_diagnostic_signatures`, `get_sales_report`, and the analytics report tools for the 7-day crash-free exit criterion and launch tracking. |

## Guardrails when an agent drives this

- It acts on a real developer account. Read first (`list_*`, `get_*`), write second, and confirm each write that is visible to customers (listing text, URLs, price) before sending it.
- `set_app_prices` **replaces the whole price schedule**; check the current one first.
- `delete_*` tools exist for localizations and bundle IDs; do not use them in this runbook.
- Keywords in the locale files are a starting point. If `keyword_insights`-style research is available elsewhere, apply it before step 5 and update the `.md` files so the repository stays the source of truth; `scripts/check_app_store_metadata.py` re-checks the limits.
- Report anything the API rejects with its message instead of retrying with altered text.

## If more of this should be automated

The gaps are in the MCP, not in Apple's API, which does expose build selection, review submission, age rating, review details, screenshot-set creation and beta-group creation. Adding those tools to the MCP (or using one that has them) would shrink steps 3, 7, 8, 12, 13 and 14. App creation and the legal declarations (DSA, App Privacy) remain web-only.
