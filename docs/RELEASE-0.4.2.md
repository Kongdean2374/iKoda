# Koda 0.4.2

This release builds on the 0.4.1 playback fixes. The app and widget use 0.4.2;
CI injects a unique build number and names the unsigned IPA accordingly. Main is
not modified. See the pull request and its Actions run for the tested commit,
actual build number, test totals and downloadable artifact.

## Translation and player controls

- The lyrics footer has one Translation switch: highlighted means on. Translation
  always appears below the original sentence. The footer reserves its own space
  instead of floating over the lyrics. Additional controls live in Settings.
- Automatic translation uses Apple's on-device Translation framework. No import
  is required. The app checks the actual language pair at runtime; the system
  may request a language-model download before offline use becomes available.
- English, Japanese, Korean and other supported source languages are detected
  independently. Mixed Chinese/foreign lines retain their Chinese text and
  translate detected foreign phrases. Unsupported phrases retain their original
  text with an availability notice. Short or ambiguous phrases can be misdetected.
- Chinese script conversion is local; Japanese kanji are not converted as Chinese.
  Generated text uses Traditional Chinese, without duplicating unchanged original
  lines. Original lyrics and singer/word timestamps remain unchanged. Translation
  follows its source row as a sentence, without word-by-word translation animation.
- Plain lyrics also support automatic translation, without invented timing.
  Optional existing imports remain supported and take priority for matching rows.
  Legacy translation-only preferences migrate to bilingual display.
- Requests are cancelled or discarded when the song, content or translation state
  changes. Translation sessions remain within their SwiftUI task lifetime.
- Audio Information is in the existing Now Playing three-dot menu. The playback
  engine, Google login and original player styling are preserved.

## Lyrics lookup and sources

The original YouLy+, Better Lyrics and LRCLIB services remain. LrcAPI and lyrics.ovh
add synced and plain-text fallbacks. Queries conservatively handle common title
decorations, artist credits and Chinese metadata variants. Candidate metadata and
available durations are checked to avoid substituting unrelated lyrics. Live and
remix distinctions are preserved. Misses can be retried; unavailable results are
not cached as permanent failures.

Settings supports up to five named custom HTTPS source templates, enabled or
disabled separately. Templates accept `{title}`, `{artist}`, `{album}` and
`{duration}`; substitutions are percent-encoded and cannot alter the endpoint.
Responses can use supported LRC, TTML, JSON or plain-text formats. Lookup sends
song metadata, not full lyrics or Koda account credentials. Custom sources must
be ones the user is permitted to access. Public services can still be unavailable
or lack a song; no source guarantees complete coverage.

## Offline music and queue restoration

- Offline Music includes only explicitly downloaded, complete files that still
  match their stored size. Playback cache files no longer appear as user downloads.
  Removing a download removes it from this list even when its active playback
  cache must temporarily remain. Existing caches are not erased by this change.
- Fully prepared finite playlists keep all source occurrences when older playback
  history is trimmed. A 600-song ordinary or smart-shuffle queue retains its full
  pool after playback, saving and restoration, including progress and repeat mode.
- Radio history remains bounded. The finite-source bound is 20,000 occurrences.
  Legacy saves without retention metadata preserve their existing finite snapshot
  within that bound; later radio additions remain subject to history trimming.
  Songs already discarded by an older version cannot be reconstructed from that save.
- Playlist pagination is completed before replacing the active queue. If the app
  is terminated before preparation completes, the previous saved queue remains;
  a partial page is not presented as a complete playlist.

## Validation and limits

Regression tests cover mixed-language planning, Traditional Chinese conversion,
original timing preservation, missing translations, lookup matching/fallbacks,
custom-source encoding, explicit offline downloads, 600-song queue restoration,
bounded radio history and legacy queue decoding. CI runs all KodaCore tests and
the release-tooling tests, builds iOS Release and universal Mac Catalyst, and
checks the actual IPA's versions, executables and zh-Hant resources. A Foundation
probe verifies that zh-Hant-TW loads the app, widget and Core translations.

Apple model downloads, device language-pair availability, translation quality,
small-screen layout, real audio routes and background behavior require physical
iPhone verification. Compilation and unit tests do not establish those results.
