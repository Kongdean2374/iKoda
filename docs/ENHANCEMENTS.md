# Koda 0.4 enhancements

This branch extends the existing SwiftUI player, audio taps and queue. English stays
the development language and the existing Taiwan Traditional Chinese translations
remain in place. New controls use the same app and KodaCore localization resources.

## Sound Center

Settings and the player menu open the Sound Center. Its ten bands use the existing
32 Hz–16 kHz filters, with ±12 dB controls, a curve, flat reset, all built-in presets
and editable saved profiles. Bass boost changes these filters rather than stacking
another bass processor. Profiles and current settings are versioned local defaults.

The existing audio tap processes the custom curve and preamp. Filter preparation
runs outside the render callback, and changes crossfade over 30 ms. Response-based
headroom and a soft overload guard limit digital overshoot; they do not constitute
a hearing-safety guarantee or a true-peak mastering limiter. The output ceiling is
applied to Koda's music players, including standby/fading players, even with EQ off.
It does not control other apps, system volume or the separate music-video player.

## Imported Traditional Chinese lyrics

The default remains original lyrics. The Chinese Lyrics screen can enable original,
translation or bilingual presentation and adjust translation size, opacity and gap.
Import a UTF-8 translated LRC or bilingual LRC with original and translation rows at
the same timestamp. Repeated timestamps are supported. For precise voice matching,
use the versioned JSON format:

```json
{"version":1,"language":"zh-Hant","lines":[
  {"time":12.5,"text":"使用者提供的譯文","original":"Original line","voice":"lead"}
]}
```

`original` and `voice` are optional; voice values are `lead`, `duet` or `together`.
Rows match the original timeline within 0.5 seconds. Partial translations fall back
to the original line. Original words, timings, backing vocals, duet alignment and
tap-to-seek remain intact. Untimed lyrics remain original because no reliable line
timeline exists. Only import content you may use. No external translation service
receives imported lyrics. The existing Apple translation option checks actual
language availability and is suppressed while imported translation is displayed.

Imports are capped at 1 MB / 5,000 lines each; the on-device cache retains at most
100 documents / 10 MB. The import screen removes the current song's translation.

## Smart Shuffle and restoration

Ordinary shuffle remains available. Opt-in Smart Shuffle uses bounded local play
and skip history, likes, recent songs and artist runs, with configurable strength,
10–50-song avoidance and liked-song weight. Constraints relax for small queues.
Manual additions and rearrangements retain their upcoming positions; saved service
playlists are not modified. Playback-history privacy controls also govern the new
history, and clearing history clears it. Profiles do not share this added history.

Queue snapshots keep current occurrence, position and optional new state. Legacy
snapshots decode with defaults. Playback resumes paused by default; a separate
opt-in switch allows a previously playing queue to resume on foreground activation
when online or when a complete local file is available. Explicit pause wins.

## Audio information and recovery

The player menu and Settings show the selected stream's declared codec/bitrate and
available decoded track information, buffer, network and player state. Unknown
values say Unavailable. Quality preferences are never presented as measurements.
The network monitor identifies Wi-Fi/cellular interfaces; it does not claim to
distinguish 4G from 5G.

Transient failures retry the same queue occurrence and position, at most three
times with 1/2/4-second delays. Tickets and load generations reject stale work.
Healthy buffered playback is retained across network changes. Authentication,
denied access and permanent errors stop recovery without skipping songs. Recovery
does not renew identities or bypass service access rules. System interruption
handling preserves user intent and never resumes after an explicit pause.

Diagnostics retain at most 100 typed events locally and can be cleared. They have
no arbitrary error text, media URL, account, cookie, token or header fields.

## Validation and limits

Core tests cover actual PCM gain/frequency response, preset persistence, lyric
alignment/fallback/voices/cache, seeded shuffle/manual order/legacy migration,
recovery policy/privacy, and injected Player failures without network requests.
The existing live-service tests remain conditional on their original environment
requirements. The release tooling and native IPA language probe are documented in
[RELEASE-0.4.md](RELEASE-0.4.md).

CI compilation and model/DSP tests cannot verify acoustic output, Bluetooth/AirPlay
routes, lock-screen and background behavior, telephone interruptions, real cellular
handoffs, installed-device translation support, import permissions, small-screen
layout or energy use. These require physical-device testing, including the requested
iPhone 17 Pro / iOS 27.3 Beta. Installation with a user's sideload signing tool also
requires a device; CI supplies the unsigned IPA.
