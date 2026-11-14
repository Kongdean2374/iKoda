# Koda 0.4.3

This release fixes the translation lifecycle and usability regressions reported on
0.4.2. It preserves the player, original lyric timing and existing English/zh-Hant
resources. App and widget versions remain aligned; Actions supplies the increasing
build number and validates the actual unsigned IPA.

## Lyrics and translation

- Lyrics Settings opens in normal browsing mode, so Chinese Lyrics and Custom
  Lyrics Sources are usable. The native Edit button enables source reordering.
- Translation belongs to the app, not to a disposable lyrics view. Hiding the
  translation, selecting another player panel or closing Now Playing preserves
  results. A bounded current-song job can finish after the display switch is off.
- Up to five upcoming songs are prepared while automatic translation is shown
  and the app is in the foreground. At most two future lyrics lookups and one
  translation engine run at once. Selecting a prefetched song adopts its existing
  work; current-song work takes priority over speculative preparation.
- A memory cache retains up to 200 source lookups. Automatic translation checkpoints
  are stored locally with a 200-song / 20 MB limit. Full ordered source text, row
  IDs, target language and engine version identify a result, so a different lyric
  provider cannot reuse incorrectly aligned text. Partial results resume only the
  missing fragments; completed results are reused when translation is shown again.
- Installed Apple language models use the iOS 26 `installedSource` session API,
  independently of SwiftUI. Missing models use a foreground system download flow;
  speculative songs never open a download prompt. Installed Chinese language pairs
  are preferred, with local Traditional Chinese conversion when needed.
- The whole unique source-language group is submitted through Apple's streaming
  batch API. Repeated sentences are translated once and mapped back to every
  occurrence. There are no 24-line completion barriers. UI updates are throttled
  and persistent checkpoints are coalesced.
- Progress is displayed in a fixed footer. When translations change row heights,
  the visible source row's position is retained without centering it again. User
  scrolling and the original natural lyric-follow behavior keep precedence.
- Current-song work requests limited iOS background execution time before the
  app can be suspended. On expiration, work pauses while its results remain saved.
  Foreground return resumes missing work. This is not a promise of unlimited
  translation while an app is suspended or terminated.

## Additional review fixes

- AudioStore's scheduled saves and explicit flush use the same serial write path,
  preventing an older snapshot from replacing a newer download index.
- A missing or damaged previously downloaded file is reconciled with download UI
  state and can be repaired under the existing Wi-Fi/cellular download policy.
- Undoing Clear Queue preserves the restored finite song pool through history
  trimming and restart, while retaining songs manually added after the clear.

## Validation

The pull request records the tested commit, unit-test totals, Actions result and
versioned IPA artifact. New tests cover persistent/memory cache reuse, content
identity, partial checkpoints, cancellation generations, prefetch priority and
adoption, background resume, row-anchor compensation and download-index races.
CI runs KodaCore and release-tooling tests, builds iOS Release and universal Mac
Catalyst, verifies the IPA executable/version/resource contents, and exercises
Foundation's zh-Hant-TW fallback against the packaged app, widget and Core strings.

Device-only checks remain explicit: translation quality and cold model startup
latency, system model download prompts, pixel-level scroll smoothness, physical
audio routes and background expiration on an iPhone. Cache hits avoid an engine
call; first-time on-device translation still depends on model readiness, song
length and hardware. No measured device speed improvement is claimed without a
physical-device measurement.

Reference: the public Dynamic-Lyrics App Store description was reviewed for the
lyrics/translation workflow. That app was not installed or benchmarked here, and
its proprietary implementation was not inspected.
