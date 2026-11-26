# Koda 0.7.0

This release follows the 0.6.3 CarPlay branch and keeps its player, CarPlay
capabilities and unsigned IPA packaging. Open a song's lyrics and tap the stack
button to inspect its available versions. The translation button keeps its
existing tap and hold gestures.

## Lyrics and translation

| Area | Behavior |
| --- | --- |
| Sources and versions | Enabled providers return candidates progressively. Results retain supplied metadata, lyrics and timing. Mirrors of the same service are alternatives. |
| Source switching | The source panel shows the active and recommended candidates, provider status, confidence, timing format and duration evidence. Choose a version without restarting the song. |
| Saved choices | Profile-scoped preferences retain the selected candidate for offline use. Restoring automatic selection keeps imports, edited translations and offsets. |
| Translation on source changes | The active candidate supplies the original lyrics and translation input to the phone and CarPlay. Work for older input cannot update the current presentation. |
| Cache separation | Candidate, base translation and contextual results use bounded automatic stores. Original text and its timing are hashed along with the version identity. Translation keys include target, mode and engine or prompt revision. |
| Matching | Title, artist and duration each contribute 25 points, recording version 15, album 5 and synchronization format 5. Missing information contributes no points. A clear conflict prevents automatic selection. A late result can be recommended without replacing displayed lyrics. |
| High quality translation | Requests Apple's high-fidelity strategy where the SDK, system and installed language pair support it. Compatibility uses the existing device translation path. |
| Contextual editing | Immersive mode passes a short passage of source lines, nearby context and base translations to Foundation Models on compatible devices. The app validates the returned row IDs before applying a passage. |
| Translation modes | Quick uses the compatible Apple engine and reuses repeated fragments. High Quality is the default. Immersive adds contextual editing after base translation and must be selected manually. |
| Translate again | Starts new work for the selected version. Existing readable lines remain available while replacement work runs. |
| Preview | Shows complete lyrics, available timestamps, source evidence and previously cached translations. Opening it does not generate a translation. |
| Manual search | Search using edited title, artist, album and duration against all enabled sources or a specific one. Search terms never change track metadata. |
| Timing | Per-version delay ranges from −30 to +30 seconds. Positive values show lyrics later. This offset is added to the existing phone or CarPlay delay. An LRC file's own positive offset advances its timestamps during parsing. |
| Edited translations | Saved line edits take precedence over a version's automatic result. They are tied to the source fingerprint and stay when automatic caches are cleared. |

## Files and data

The candidate catalogue is kept separately from per-profile preferences. Refresh
keeps the previous verified catalogue when lookups fail. Atomic writes replace
readable snapshots. Automatic character conversion and translations are stored
separately from user files. The default automatic disk budgets are 20 MB for
candidates, 20 MB for base translation and 10 MB for contextual edits. The total
can be changed in Chinese Lyrics settings. A saved
candidate can populate the player offline even after the automatic catalogue has
been evicted.

Older imported translations lack a candidate fingerprint. The original file
remains available and can be explicitly attached to the current synced version
from Chinese Lyrics settings. Inspect the selected lyrics and timestamps before
attaching. The original source, original lyric timestamps and cloud song
metadata are preserved. Automatic caches from previous releases are not treated
as matches for the new version identities.

## Platform limits and iPhone testing

- Apple Translation support and language download requirements vary by system
  and language pair. The app reports the strategy it requests. The framework
  does not expose the model used for each translated line.
- Foundation Models requires a device with the on-device model available,
  enabled and ready, and the required language support. Base translation and
  original lyrics stay available when contextual generation is unavailable,
  rejected or suspended. High temperature and Low Power Mode constrain work.
  One model worker gives the current song priority. If resources permit and
  its work is complete, the worker can prepare the next song.
- CarPlay and Live Activity are subject to Apple signing, refresh and background
  execution limits. See the existing CarPlay signing documentation.
- On iPhone, switch among three lyric versions while playback continues, seek
  during a translation, return to an earlier version offline, and confirm each
  version's timing and hand-edited text after restarting the app. To check
  fallback behavior, repeat with an unavailable source and an uninstalled
  translation language.
- With Apple Intelligence enabled, try an original test song with repeated
  phrases, different speakers, and mixed-language lines. Verify meaning and
  natural Traditional Chinese by listening. Repeat in Low Power Mode.
- On a real CarPlay connection, verify current lyrics and translations after
  source changes, seeks, pauses, reconnection and the end of playback. Compare
  the phone delay and the independent CarPlay delay. Check playback while the
  screen is locked and when the Live Activity is dismissed.

See Apple's [Translation](https://developer.apple.com/documentation/translation)
and [Foundation Models](https://developer.apple.com/documentation/foundationmodels)
documentation for device and language availability.
