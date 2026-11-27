# Koda 0.7.1

## Translation and presentation

- Immersive mode has separate states for original lyrics, Apple Translation,
  model availability, contextual translation, and output validation. The long
  press menu includes Translation Diagnostics with real row counts, elapsed
  times, cache reads, language support, requested Apple strategy and resource
  limits. The local copy contains statuses and counts. It omits lyric text,
  track names, account identifiers and raw error contents.
- Foundation Models reads consecutive original lines across phrasing and
  stanza breaks. Short tracks provide their full text to each passage. A model
  overview supplies common context for longer tracks, with bounded excerpts
  when the entire track exceeds the input budget. Apple translations are
  optional hints and fallback text. Output is validated against original IDs.
  Valid rows from a partial response are retained and only the missing rows
  receive a smaller retry. Later passages still run after a failed batch.
- The revised contextual cache key retires prior immersive output from playback.
  Existing Apple base caches, imported translations, original versions, manual
  edits and calibration remain compatible.
- The Translation Sources picker remembers a choice for the song and original
  version on this device. Compare provider, imported, Apple Translation and
  contextual lines alongside the original. Manual edits retain priority.
  Chinese provider text can be converted to Traditional Chinese, with the
  script conversion shown separately from semantic translation.
- On a portrait iPhone, enabling translations in the lyrics panel uses the
  compact 40-point cover and a three-button transport. The controls button
  expands volume and time-skip buttons. Lyrics keep their font size, timing and
  scroll behavior. Opening another player panel or turning translation off
  restores the full layout. The Lyrics settings toggle persists.

## Provider formats

YouLyPlus upstream defines a language-tagged `translation` object in each
JSON row. Its client also accepts a `translations` map keyed by language. TTML
subtitles use `translation xml:lang`, and `text for` joins to the original
line's key. These paths now preserve aligned translations separately from the
original. The parser also accepts exact time pairs in LRC when the source
explicitly declares a translation language. Untagged duplicate times remain
original rows, including simultaneous singers.

Public-response checks used generic song metadata and recorded field names
only. LRCLIB returned its text, timing and lyricsfile fields without a separate
translation field in the sampled response. LrcAPI returned an `lrc` field,
which is now recognized by the candidate parser. The sampled BetterLyrics main
endpoint returned 401, the sampled Lyrics.ovh request returned 404, and the
initial YouLyPlus request timed out. Protected endpoint behavior is preserved.
The published YouLyPlus format and BetterLyrics TTML wrapper were exercised
with original test fixtures.

Sources: [YouLyPlus JSON model](https://github.com/ibratabian17/LyricsPlus/blob/gelato/internal/domain/v2.go),
[YouLyPlus TTML parser](https://github.com/ibratabian17/LyricsPlus/blob/gelato/internal/parsers/ttml.go),
[Better Lyrics](https://docs.betterlyrics.org/reference/get-lyrics),
[LRCLIB](https://lrclib.net/docs), [LrcAPI](https://docs.lrc.cx/docs/QuickStart/).

Device translation remains the default. The existing injectable engine
interface supports testing or future adapter work. This release includes no
remote translation adapters or credential collection. Future remote adapters
require explicit opt-in, disclosure of transmitted data and fees, and Keychain
storage for credentials.

## Recording verification and recommendation

0.7.0 ranked identity score ahead of lyric quality. This release checks
recording evidence, ordered original-text agreement and timing separately.
Meaningful text and repeated occurrences remain in the sequence. Corroboration
requires a known independent upstream and a credible recording anchor.
Time alignment and available ISRC evidence prevent matching lyrics alone from
confirming a different recording. Missing metadata is shown as missing or
unconfirmed. Explicit conflicts and invalid timelines are excluded from
automatic recommendation.

Among credible, compatible versions the ranking favors complete word timing,
high coverage, partial word timing, line timing, then plain text. Coverage is
the share of normalized sung text covered by valid, ordered word timing that
matches the displayed originals. The details also count fully covered lines,
invalid timestamps and voices. A later better candidate changes the
recommendation while the pairing already being read and any manual choice stay
in place. A bounded cache reuses expensive pair comparisons off the main actor.

## On-device checks

Use the long-press diagnostics while comparing results on an eligible iPhone.
Check the model readiness status, confirm some valid rows are counted as
unchanged when appropriate, and verify base fallback with Apple Intelligence
disabled. Try an original lyric with a phrase spread over adjacent lines and
verify that the natural translation retains the speaker and negation. Check
seek, pause, singing-line highlights and manual scrolling while switching
between compact, expanded and full layouts. Connect CarPlay and confirm the
selected translation source and independent display delay. Model semantics,
power consumption and car display cadence require real hardware.
