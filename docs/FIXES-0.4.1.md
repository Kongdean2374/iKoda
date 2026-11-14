# Koda 0.4.1 regression fixes

This patch is based on 0.4.0 build 10601 (`4328184`). It preserves the English and
Traditional Chinese resources, existing interface, service authentication and data
formats. The changes address reviewed code paths; they are not a claim that every
reported symptom was reproduced on an iPhone.

## Collections and user intent

- Online playlist playback owns metadata pagination outside the scrolling view.
  All source pages finish before the first ordinary/smart shuffled song is selected.
  A 600-song collection therefore includes later pages in the initial candidate pool.
  Existing ordered pages and cursor history are reused; empty pages, duplicate song
  occurrences, cancellation, retries and repeated cursors are handled explicitly.
  Preparation is bounded to 200 pages / 20,000 songs and never silently starts a
  partial playlist. This loads metadata, not all audio files.
- Progress, Cancel and Retry remain available when no current song exists. A failed
  page keeps the prior queue intact; retry starts at the last successful checkpoint.
  Home cards, Siri, Play Next and Add to Queue use the same complete-source boundary.
- Delayed radio and song-link results cannot override a later pause, selection or
  queue edit. Radio prefetch records a later end-of-queue advance request instead of
  ignoring it. Song links require the exact requested ID, never a recommended substitute.
- Undoing a cleared queue restores the removed songs without removing songs added
  afterward. Deliberate duplicate occurrences and manual ordering remain protected.

## Playback and recovery

- Retry reservations do not spend the retry budget. Only a valid, online reload that
  actually starts consumes one attempt. Connectivity is rechecked after asynchronous
  stream invalidation. Three real attempts retain the 1/2/4-second backoff.
- Explicit Play can replace a failed paused item. Successful explicit audio-session
  activation can clear a stale interruption latch when the system omitted its end
  notification; activation failure does not force playback.
- Confirmed missing/truncated/undecodable local files are rejected using a runtime
  file-version identity. A late failure cannot delete newly downloaded bytes.
  Valid files are retained for network, authorization, media-service and temporary
  file-protection failures. Download intent is preserved, and legitimate online
  replacement uses the same occurrence, position and bounded retry policy.
- HTTP cache failures retain their status through Foundation/AVFoundation wrapping:
  5xx and 408 can retry; authorization, forbidden, unavailable and rate-limit responses
  stop. Invalid response ranges/types cannot be committed as playable cache bytes.
- Actual item changes refresh duration and timing even when the logical queue already
  advanced. Manual Next to a parked AutoMix standby seeks to the beginning; automatic
  AutoMix still uses its planned entrance. Old delayed transition starts are invalidated.
- Queue snapshots serialize version validation and atomic file replacement together.
  Natural handovers reset the playhead before saving the new song. Existing JSON
  snapshots remain compatible.
- Media-service reset handling rebuilds playback objects, observers and processing
  while preserving song, position and pause/play intent. This differs from telephone
  interruption handling and still requires the system's real reset test on a device.
- Cold-launch resume requires the app to be active at the moment of restoration.
  Leaving active state revokes that permission without pausing legitimate background
  playback that has already started.

## Sound, lyrics and video

- Main, fading and incoming music players share one gain budget. Common scaling
  preserves their relative fade envelopes; reductions are written before increases.
  AutoMix processing has a post-automation overload guard. This bounds coordinated
  digital gains; it is not a hardware, hearing-safety or inter-sample true-peak meter.
  The separate MV player's volume remains outside the music output ceiling.
- Imported lyric alignment uses one-to-one maximum matching within the existing
  tolerance. It handles the 0.6-second line spacing / 0.4-second early translation
  case without changing original timestamps. Explicit original/voice constraints
  remain binding, and generic LRC matches retain chronological order. Closest-edge
  preferences are deterministic; no global minimum-distance claim is made.
- Music selection cancels pending MV loads, prerolls, seeks and autoplay countdowns
  immediately. Generation checks reject old success, error, caption and cleanup
  callbacks. An already prepared video remains available for explicit resume.
- The Mac speaker button uses the existing mute state and retains the chosen volume,
  instead of resetting it to 70%. Adjusting the slider explicitly unmutes it.

## Downloads and voice search

- Collection download preparation has a cancellable batch identity. Stop/Remove,
  Remove All and replacement requests invalidate both the task and its late result.
  Navigating away keeps the manager-owned batch running, including empty pages
  whose continuation cursor still advances.
- Download backoff releases active slots so other songs can proceed. Six attempts
  lead to an explicit failed state with Retry; there is no unbounded background loop.
- Changing cellular permission cancels old transfers/session work. Missing ranges
  resume through a new session with the current permission; stale completions cannot
  update replacement jobs or commit canceled bytes.
- Voice authorization checks cancellation and generation after every await. Late
  permission grants cannot start the microphone. Cleanup changes the shared audio
  session only when that generation actually acquired it, and stale callbacks cannot
  stop a newer recording session.

## Verification boundaries

Regression tests use controlled page loaders, radio/stream results, PCM buffers,
permission gates, download completions and file writes. Local AVFoundation tests
exercise real preloaded-item handover and failed-item paths without external services.
The original conditional live-service suites remain conditional.

The PR records the final Xcode test/build results and exact IPA artifact. CI validates
the unpacked IPA's App/Widget versions, arm64 binaries and compiled zh-Hant resources,
then loads translations with Apple's Foundation locale selection. Physical iPhone
testing is still needed for actual audio routes, media-service reset, calls, background
transitions, cellular handoffs, recording, acoustic output and sideload installation.
