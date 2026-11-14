# Traditional Chinese (Taiwan)

Koda keeps English as its development language and supports `zh-Hant`. iOS selects
Traditional Chinese automatically for a Traditional Chinese language preference,
including `zh-Hant-TW`; no custom language switch or playback/login changes are needed.

## Resources and coverage

- `Koda/Localizable.xcstrings`: app screens, settings, onboarding, library, search,
  playback, lyrics controls/sharing, downloads, audio settings, profiles, dialogs,
  errors, VoiceOver, video UI, Siri/Shortcuts metadata and existing Mac presentation.
- `Koda/AppShortcuts.xcstrings`: localized invocation phrases with parameter tokens.
- `Koda/InfoPlist.xcstrings`: microphone, speech recognition and photo-library purposes.
- `KodaWidgets/Localizable.xcstrings`: widget, Control Center and shared intent text.
- `KodaCore/Sources/KodaCore/Resources/{en,zh-Hant}.lproj`: package-owned display names
  and errors, loaded with `Bundle.module` rather than the application's bundle.

The Xcode project uses filesystem-synchronized groups: resources under `Koda` belong
to the app, resources under `KodaWidgets` belong to the extension, and `Shared` Swift
sources belong to both. `knownRegions` includes `zh-Hant`; developmentRegion is `en`.
Generated string symbols are disabled: the original English labels include case and
punctuation variants that normalize to the same Swift symbol; lookups use literal keys.
KodaCore declares `defaultLocalization: "en"` and processes its Resources directory.

Dynamic strings are localized at creation; custom SwiftUI labels that accept static
keys use `LocalizedStringKey`. Stored enum raw values, preference keys, API arguments
and identifiers stay unchanged. Number/string format types and line breaks are retained;
count-sensitive AppIntents entries have English plural forms and Chinese equivalents.
Concise Taiwanese wording and existing flexible/wrapping layouts are retained. Widget
tiles allow two lines and scale to 80%. A physical-device small-screen review is still required.

## Deliberately untranslated

Song/album/artist and user-created names, lyric bodies, external service descriptions,
search results, server error reasons and Google/YouTube sign-in web content stay in their
original language. Stored genres remain stable and are localized only for display.
Koda, YouTube Music, YouTube, AirPlay, Last.fm and Discord keep their official names.
Technical formats/resolutions, URLs, diagnostics and identifiers are not translated.

## Verification

Run `python3 scripts/validate-localization.py` to validate catalog completeness and
placeholder parity. Run the original `cd KodaCore && swift test` on the supported Apple
SDK; localization tests additionally inspect actual package resources, fallback,
formatting and stable stored identifiers.

The existing `.github/workflows/build.yml` keeps the Xcode 27 Release build and unsigned
`Payload/Koda.app` IPA packaging. After packaging it extracts `Koda.ipa` and runs:

```sh
bash scripts/verify-localization.sh localization-check/Payload/Koda.app
```

The script compiles a bilingual macOS probe app and launches it with `-AppleLanguages
'(zh-Hant-TW)'`. This avoids the English-only Swift interpreter host influencing bundle
selection. It checks compiled app/widget/Core resources, Foundation locale selection, actual
translated strings and permission strings. It does not substitute for launching the app
on an iPhone. The IPA artifact is uploaded only after these checks succeed, as
`Koda-<commit SHA>` containing `Koda.ipa`, suitable for signing with AltStore/Sideloadly.
Build logs are uploaded separately, including failed builds. See the PR and Actions run
for actual outcomes; source checks alone do not establish build or device-test success.
