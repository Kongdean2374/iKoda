# Koda 0.6.0

This release descends from `codex/koda-0-5-1-deep-sleep`, commit
`eea5bf327dd747e37266390a8a7de7c92850975f`. That base includes the stacked
0.4.x and 0.5.0 changes and the complete 0.5.1 sleep session work. Its verified
release was Build 13101, with iOS Release, universal Mac Catalyst, Core tests and
both iPhone Simulator sizes passing. No 0.5.2/0.5.3 branch existed when development
started. The PR targets this base; it does not rewrite or merge `main`.

## YouTube Music playlists

The cloud playlist ID is the identity. The app keeps a read-back cache and a
bounded operation journal, not a second editable copy of a cloud playlist.
Creation, additions, occurrence-specific removals and renaming use the existing
authenticated YouTube Music service and are confirmed by fresh reads. These are
unofficial service endpoints; Google does not promise compatibility or official
support. No authorization, DRM or paid-access requirement is bypassed.

Only server-provided editing capabilities authorize changes. A `PL` prefix or a
matching title is not ownership evidence. Special collections are not treated as
ordinary editable playlists. Remote deletion and reordering remain unavailable
without verified safe support. Library refresh is explicit and can bypass normal
background throttling. An ambiguous write is checked again before any retry;
unknown Create responses cannot silently create a second playlist. External edits
are retained, and account switches invalidate stale work.

Existing `userPlaylists` data and backup formats remain readable. People without
legacy local playlists do not get a migration wizard. Legacy data is backed up or
explicitly copied to a confirmed cloud playlist before an optional hide action;
it is never silently deleted during upgrade. Downloads, queues, sound settings,
translation caches and playback history remain on the device as before.

## Home and Koda Flow

Home prioritizes the signed-in account's cloud playlists. Display pins/order are
local preferences; they do not rearrange the remote playlist. Explicit Play and
Shuffle controls prepare the complete paginated source. Recommendations remain
secondary and do not become a new collection of permanent shortcut cards.

Koda Flow reads one explicitly selected cloud playlist in full. It uses declared
song lengths and randomized arrangement only, with bounded optimization outside
the main actor. Listening history, recommendations and other playlists cannot
contribute songs. The preview reports estimated duration and the difference from
the request, including insufficient source duration and skipped unknown lengths.
Any deduplication affects this queue only. Crossfade/AutoMix makes elapsed time an
estimate, not a promise to stop at an exact second. Flow does not alter the remote
playlist and ends without fetching a recommendation radio. The existing sleep
timer remains the only hard-stop timer.

## Music Catcher

The Search screen opens a deliberate microphone recognition session, followed by
YouTube Music candidate search. A user chooses the version before previewing,
liking or adding it through the verified cloud workflow. No candidate is saved
automatically and no microphone recording history is stored. Cancellation,
permissions, account changes and newer playback intentions reject late callbacks.

Recognition uses Apple's public ShazamKit API for ambient microphone audio, not
audio captured from other apps. The signing App ID must support Apple's ShazamKit
service. A sideloaded build can be rejected when its signing identity lacks that
service; an unsigned IPA alone cannot guarantee recognition availability. Manual
search remains available. No new paid recognition API or third-party login is used.

Apple references:
- [SHSession](https://developer.apple.com/documentation/shazamkit/shsession/)
- [Enable ShazamKit for an App ID](https://developer.apple.com/help/account/services/shazamkit)

## Validation and limitations

The PR records executed Core/tooling/UI counts and the exact commit, run, build
number and downloadable IPA after CI. Early builds are not final delivery evidence.
App/Widget versions, Mach-O executables, ZIP integrity and compiled English/zh-Hant
resources are checked against the actual IPA. Original translations and the GPLv3
license remain, while microphone usage explains both voice search and recognition.

Simulator tests mount real production views with deterministic cloud/recognition
service boundaries. These verify UI state and read-back behavior, not a signed-in
Google account or actual Shazam recognition. Core tests cover paging, permissions,
ambiguous writes, concurrent changes, Flow selection and recognition cancellation.
The existing translation controls, sound settings and deep sleep tests remain.
New component cases exercise 600-row selection, cloud merge/source preservation,
confirmed creation, a lost read-back followed by a duplicate-safe retry, Home's
play/shuffle entry points, source-only Flow previews, and Catcher result selection,
verified likes, cancellation and no-match recovery. Home and Flow also receive
Traditional Chinese, large-text, dark-appearance screenshots. These cases do not
start audio streams or count mock recognition as successful live recognition.

A real Google account is still needed to confirm that a change appears in the
official YouTube Music app and vice versa. An iPhone with a supported signing App
ID is needed for live recognition, microphone permission, audio-route and playback
restoration checks. Long background playback, two-hour locked-screen sleep expiry,
Bluetooth/USB/AirPlay/PiP, VoiceOver, haptics, battery use and audible transitions
remain physical-device acceptance items. iOS decides background execution and
when Now Playing cards disappear; CI success cannot establish those outcomes.
