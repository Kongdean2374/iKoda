# Koda 0.7.2

## On-device translation

- Lyrics use a shared language profile. Whole-song and paragraph evidence protect
  short Latin-script lines from spurious language changes. Kana, Hangul and
  sustained language changes still identify multilingual sections. Blank rows,
  non-text rows and standalone vocalizations stay in the original.
- Apple Translation checks the complete source/target pair on the requested
  strategy. It prefers supported Taiwan Traditional Chinese and records the
  selected target, the response locale and alternative Taiwan routes. If only Hong Kong Chinese or
  another Chinese locale is supported, diagnostics identify that route. The
  Simplified-to-Traditional conversion changes script. It does not translate
  regional grammar or guarantee Taiwan vocabulary.
- Pure AI uses Foundation Models with original lyric context and no Apple
  Translation session, hint fields or language download. Its automatic view
  shows validated model results and the original for gaps. User edits still
  take priority, and users can explicitly choose an available other source.
  Immersive mode may use
  Apple results already available when a passage is generated. Original-language
  context can prepare and generate while Apple Translation is still working.
- A secondary unsupported language no longer prevents the song overview.
  Supported passages continue with full or adjacent originals if the overview
  cannot run or fails. The timeline and voice layout stay attached to original rows.
- One model invocation runs at a time. Each passage can retry missing results in
  smaller batches for recoverable errors. Two consecutive generation deadlines
  end that run. If a model call does not immediately honor cancellation, Koda
  reports the timeout while keeping the invocation slot occupied until it exits.
  Apple Translation also has a progress-sensitive deadline. Dynamic lyrics
  prioritize the audible passage and ensuing passages when work starts.
- The player shows the current stage and completed rows. Diagnostics distinguish
  validated, copied from a matching refrain, reused from cache, unnecessary,
  unsupported and failed results. Valid output remains visible during retries.
  Users can resume failed rows or regenerate a selection from Compare Translations.

## Translation versions and storage

- Compare uses available Apple Quick, Apple High Quality, Immersive AI, Pure AI,
  embedded, imported and user-edited results. Filters show all lines, differences
  or unfinished lines. A preferred source is stored against the original version.
- Application caches include original content identity, source routes, mode and
  language/profile algorithm version where applicable. The model cache includes
  the prompt revision. Old cache files are left to the existing eviction policy.
  The old immersive result remains available for comparison while present.
- Keep AI Translation saves an explicit copy to the local account profile,
  outside the automatic cache. Its metadata contains the original fingerprint,
  mode, engine, requested language pair, revisions and validated row IDs.
  The public Foundation Models API does not expose a model build identifier.
  Koda separately preserves and prioritizes user edits. Removing a kept AI
  translation does not clear the account's user edits.
- No external translation service or login is used.

## Device acceptance

Test an English song with a refrain containing standalone singing sounds. Inspect
the language profile and check that only meaningful lines produce requests.
Compare with a genuinely multilingual track. Repeat the same track with Immersive
and Pure AI and compare route, generated row counts and total time from the long
press diagnostics. Verify that manually preserved translations remain available
after clearing the automatic cache and reopening the app.

Model timings, semantic quality, cancellation latency on physical Apple hardware,
actual regional language-pack support, battery/thermal impact and CarPlay display
timing require a real iPhone. Automated fixtures test control flow and validation.
They do not measure Apple Intelligence translation quality.
