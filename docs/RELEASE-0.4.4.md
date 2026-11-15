# Koda 0.4.4

This update simplifies the translation control and prevents an inline music video
from treating a return to the foreground as a new playback request. It retains
the existing translation cache, Apple on-device translation, lyric timing and
English/Traditional Chinese interface.

## Translation control

- A 44-point circular translation icon replaces the wide labeled button. A tap
  shows or hides translation; the selected appearance remains highlighted.
- A short status beside the circle reports preparation, translation, completion
  or an unavailable language. Detailed progress is not placed over lyric rows.
- Holding the circle for half a second produces haptic feedback and opens live
  progress and a settings link. The exclusive gesture recognizes either the hold
  or the tap, so releasing a successful hold cannot toggle translation.
- The details sheet and its settings route omit the display toggle. The icon is
  the display switch; the normal app settings page still has its existing option.
- VoiceOver offers activation and a separate details action. Keyboard activation
  handles key-down only, avoiding repeated toggles while a key is held.
- The fixed footer and lyric scroll-position compensation remain unchanged.
  Opening details or hiding translation does not clear completed translations.

## Video playback intent

- An ordinary inline video pauses when the app actually enters the background.
  Becoming active updates visibility without issuing a play command. The selected
  video and position remain available for explicit resume.
- Watch-page reconstruction does not restart a previously paused or cancelled
  selection. Pending stream, seek and autoplay callbacks remain generation-gated.
  Reopening that same stopped selection shows an explicit Play control, including
  when a cancelled load has not installed a player item yet.
- Observed playback rate is state, not a new listener request. Native external
  playback controls require permission from the existing PiP/AirPlay presentation;
  a later music selection or app-level cancellation revokes old permission.
  A normal pause inside an authorized external presentation still permits its
  native Play control. After switching to music cancels the video, explicitly
  resume the video in Koda before using its old external controls again: the
  AVPlayerLayer API does not identify whether a late rate came from a native
  button or system restoration.
- Existing PiP and AirPlay playback are retained. A bounded, selection-specific
  handoff accommodates automatic PiP callbacks arriving just after background
  entry; it cannot be used by ordinary rate changes or foreground entry.

## Verification

The pull request records the exact tested commit, KodaCore and packaging results,
iOS Release/Mac Catalyst build results, and the versioned unsigned IPA artifact.
App and widget versions are advanced together, while Actions supplies the build
number. The packaged IPA is checked for executable validity, matching versions,
and actual zh-Hant resources loaded with a zh-Hant-TW language preference.

Actual touch/VoiceOver interaction, haptic feel, iOS background/automatic PiP
callback ordering and physical AirPlay devices still require device validation.
System translation model availability and cold-start latency retain the limits
documented for 0.4.3. No physical-device test is claimed from source review or CI.
