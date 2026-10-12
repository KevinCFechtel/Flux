# Android localization: Weblate-ready resource contract

Status: **resource foundation introduced; translation and full UI extraction are not complete**.

## Product languages

The established `MOBILE_PRODUCT_SEMANTICS.md` contract calls for seven native-mobile languages:

| Language | Android resource folder | Translation status |
| --- | --- | --- |
| English (source) | `values/strings.xml` | Canonical English |
| German | `values-de/strings.xml` | Review/translation pending |
| Spanish | `values-es/strings.xml` | Review/translation pending |
| Galician | `values-gl/strings.xml` | Review/translation pending |
| Dutch | `values-nl/strings.xml` | Review/translation pending |
| Tamil | `values-ta/strings.xml` | Review/translation pending |
| Turkish | `values-tr/strings.xml` | Review/translation pending |

The six translation files are intentionally empty until human-reviewed content exists. Android uses the English default for missing entries. **Empty language catalogs are scaffolding, not translated UI.** Do not turn on an in-app language picker or advertise complete translation coverage before review.

## Weblate component configuration (when service is connected)

- **Format:** Android String Resource (monolingual).
- **Repository:** `KevinCFechtel/Flux`.
- **Branch:** `main`, with Weblate changes delivered through reviewed commits/PRs.
- **Source language:** English (`en`).
- **Monolingual base:** `android/app/src/main/res/values/strings.xml`.
- **File mask:** `android/app/src/main/res/values-*/strings.xml`.
- **Languages:** `de`, `es`, `gl`, `nl`, `ta`, `tr` (English comes from the base).
- **Template for new translations:** Empty.
- **Translation workflow:** Translation reviewers own target catalogs; application changes own the English source catalog. No generated pseudo-translations or automatic writes to translation files as part of code changes.

Weblate is **not connected or configured on a live instance** by this change. This document records setup inputs; the connection needs its own Weblate administrator action.

## Developer rules

1. All user-visible UI, settings, notification, error, widget and accessibility copy belongs in Android `strings.xml` files. Compose uses `stringResource(R.string.key)`; callbacks/background workers use `context.getString(R.string.key)`; plural messages use Android `plurals` and `pluralStringResource`/ `getQuantityString`.
2. Use semantic, stable snake_case keys such as `feed_discovery_empty`. Never reuse a key for changed meaning; update source English when the wording genuinely changes.
3. Format arguments must be positional and typed: `%1$s`, `%2$d`; preserve exact placeholders across languages. Do not concatenate fragments into sentences or assume identical plural rules.
4. Use `translatable="false"` for literal product/technical values, URLs, identifiers and tokens; do not translate user/server-provided feed titles or category names.
5. Do not fabricate machine translations to make the directory look complete. Weblate translations should be reviewed before they become release-supported.
6. Resource extraction is incremental: C1.1 covers navigation/feed creation, C1.2 covers settings destinations and selected timeline controls, and C1.3 covers additional settings, download management and Reader controls. **Remaining Kotlin hardcoded strings must still be extracted** in settings, timeline, Reader, player, listening list, sync states, widgets, notifications and accessibility labels before C1 is declared complete.
7. Locale formatting belongs to Android's locale-aware date/number APIs, not English-only string concatenation. Validate all seven locales for truncated text, RTL where applicable, correct plurals, accessibility and fallback.
8. Add or update tests for placeholders and source/translation parity when target catalogs are populated.

Do not count this repository preparation as a completed C1 translation rollout.
