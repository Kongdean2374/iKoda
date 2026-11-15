# Koda 0.5.1 — combined release

This release includes all playlist management, output-specific sound and interface
refinements described in [0.5.0](RELEASE-0.5.0.md), plus the deep sleep timer below.
It descends from `codex/koda-0-5-0-playlist-device-polish`; it does not replace the
unmerged 0.4.x/0.5.0 history with `main`. App and Widget versions are both 0.5.1.
The existing Actions formula supplies the actual build number for each run/attempt.

## Sleep timer

- The existing player menu and countdown pill remain in place. Presets are 5, 10,
  15, 30, 45, 60, 90, 120 and 180 minutes, with a custom whole-minute duration from
  1 through 720 minutes. Active timers can be cancelled, extended or reset.
- Scheduling and the final action are separate: choose a deadline or the end of
  the selected song, then choose ordinary pause or Finish Playback Session.
  Finish Playback Session is the default. A countdown acts when its deadline is
  reached; it does not wait for the song to end. End-of-song schedules track the
  selected queue occurrence and are cancelled when another song is selected.
- A versioned, persisted absolute `Date` is the authority. An in-process task and
  playback/lifecycle checks only wake the policy for evaluation. A timer revision
  rejects obsolete callbacks after cancellation, extension or resetting. A durable
  completion record prevents launch, network recovery or audio-interruption
  callbacks from restoring expired playback intent.
- Complete finish retains the queue, current song and valid position, and keeps
  playlists, favorites, downloads and settings. Only an explicit playback command
  opens a new listening session. Cancelling a timer does not itself start music.
- Finish invalidates playback generations; cancels recovery, radio/pagination,
  stream preparation, analysis, transitions, metadata/artwork and lyric preparation;
  pauses and removes native audio items; detaches rendering/observations; clears
  Now Playing information; and deactivates the shared audio session only when no
  Koda video/PiP/AirPlay or voice-recording owner still needs it.
- Shared audio-resolution and analysis work use subscriber cancellation. Stopping
  music must not cancel an independent download. Already completed translation,
  artwork and audio cache data remain available. Any write already in progress may
  finish; obsolete results cannot start playback or republish Now Playing metadata.

## Validation

Core regressions cover date-based countdowns, revisions, extension/reset/cancel,
expired launch, sticky completion, end-of-song identity, queue/position retention,
manual restart, late callbacks, stream/analysis cancellation, and background
translation/artwork gates. Simulator tests exercise the actual sleep settings
component with short assertions against stored deadlines, without waiting hours.

Exact executed/passed/skipped counts, Xcode Release/Mac Catalyst results, Simulator
outcomes and the immutable IPA artifact are recorded in the PR after CI. Packaging
checks open the actual IPA, compare App/Widget versions, verify executable files,
and exercise compiled English/Traditional Chinese resources including sleep labels.

## Platform limits and device acceptance

iOS decides whether background code runs and when its playback card disappears.
While audio keeps the process running, Koda can evaluate the deadline; a suspended
or force-quit app cannot promise execution at an exact instant. On next launch or
resume, an overdue timer is consumed before automatic playback is considered.
There is no private API, artificial background mode or forced app termination.

Apple translation cancellation is cooperative. Koda immediately closes admission,
invalidates results and releases its finite background assertion after checkpointing
saved text; it cannot promise that the OS translation process stops instantly.
An anonymous visitor-identity request already shared with other features may finish
within its existing timeout; cancellation never changes login or authorization.

Real iPhone checks remain necessary for a two-hour locked-screen countdown, calls,
network changes at expiry, Bluetooth/AirPlay/PiP ownership, Control Center/card
behavior, physical haptics, VoiceOver, battery usage and audible transition quality.
CI and Simulator results are not a substitute for those checks.
