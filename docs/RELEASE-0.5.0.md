# Koda 0.5.0

This release builds on `codex/koda-0-4-4-translation-control-video`, including the
unmerged 0.4.x upgrades. It retains the existing navigation and Now Playing layout,
English/Traditional Chinese interface, music/video playback, translation cache,
EQ engine, account integration and queue formats.

## Playlist tools

- Existing playlist/song menus open a native selection sheet. Select individual
  occurrences, all songs or none; search the list; play selected songs next or add
  them to the queue. Normal browsing keeps its single-song gestures and appearance.
- Copy to an existing or new local playlist, move between local playlists, or
  remove selected occurrences. These operations never call YouTube Music mutation
  APIs. Existing destination IDs are kept once, matching Add to Playlist semantics.
- Duplicate review separates exact stable-ID matches, metadata-based possible
  matches and special editions such as Live, Remix, Cover and Instrumental.
  Suggestions never delete anything automatically; the listener chooses removals.
- Merge two or more local/saved online playlists, arrange source order, preview
  the resulting count, optionally exclude exact IDs, and save as a new local
  playlist. Songs keep their order within each source; source playlists are kept.
  Explicit merges can retain repeated occurrences without changing legacy add
  behavior or requiring a new persisted playlist format.
- Online tools use the existing complete pagination loader and reuse successful
  checkpoints for retry. Cancellation or failed pagination cannot silently save a
  truncated result. The existing per-source safety bounds remain in effect.
- Heavy comparison, merging, JSON encoding and temporary-file writes run outside
  MainActor. A version/profile check and a short atomic rename publish the result.
  Existing background saves share the commit lock, so stale saves cannot overwrite
  a newer edit. Errors remain visible and no in-memory deletion precedes commit.
- Copy/move/remove offer undo within the tool session. Later appended songs are
  preserved; ambiguous subsequent reorder/deletion produces an explicit error.
  Tokens expire after 64 newer undoable edits or a profile switch. Creating a new
  merged playlist is reversible using the existing Delete Playlist action.

## Output-specific sound

- Sound Center gains Device Sound Settings. Bind the current iOS output identifier
  or a recognized output type to a built-in EQ or saved complete sound profile.
  Bindings, the default fallback and the automatic-switch preference are persisted.
- Automatic switching starts off. Unassigned recognized outputs can keep current
  sound or use a chosen default. Unknown/multiple outputs and deleted profiles
  preserve current sound. Device identifiers are local OS hints, not model names,
  serial numbers or guaranteed permanent hardware identity; type/manual assignment
  remains available when matching is unreliable.
- A 650ms debounce and generation check reject outdated route changes. Manual EQ
  changes win until a genuine output change or explicit Use Assigned Sound. Editing
  another device's assignment does not reset that override.
- Full profiles reach the existing DSP atomically. Its 30ms filter transition is
  retained; automatic output-ceiling increases ease in over 250ms and decreases
  apply immediately. The existing shared AutoMix/Crossfade output budget remains
  in force. Transitions use monotonic time and never recreate a player or seek.
- The existing headphone-disconnect pause remains. These controls affect Koda
  music only, not system volume, other applications or music-video audio.

## Interface refinements

- A shared compact-control rule supplies 44pt touch targets without forcing every
  icon to the same visual size. Song menus have their own reserved hit area, and
  music/video mini-player and lower player controls are easier to target.
- Song rows accommodate accessibility text sizes with extra lines and natural
  height; ordinary text sizes keep their original arrangement.
- Existing system glass remains the default. Selected floating controls use a
  solid system-color alternative for Reduce Transparency, without layered blurs.
- Reduce Motion is respected by affected press, playback, skip, cover, lyric
  following and volume animations. Translation tap/hold/haptic semantics remain.
- Paused/background lyric/progress/ambient timelines stop unnecessary updates.
  Seek still updates through the original time anchor; playback resumes using the
  current clock. Mac video progress is isolated from the rest of its control bar.

## Verification and limits

The PR records exact Core/tooling test counts, skipped live tests, Xcode build
results and the immutable IPA artifact. App/widget versions are 0.5.0; the existing
Actions formula provides the actual increasing build number without version
commits. IPA checks inspect real plists, Mach-O executables, compiled resources
and Foundation's zh-Hant-TW fallback, including the new feature strings.

A separate Simulator job runs real production SwiftUI components inside a
DEBUG-only, offline fixture. It tests translation tap/hold, local selection and
merge, the device-sound settings entry, and captures light/dark Traditional Chinese
screens with accessibility text and reduced effects. It uses available iOS 26+
iPhone runtimes; a missing runtime is explicitly reported as skipped. The fixture
is absent from Release builds. This is component validation, not a complete
signed-in navigation or playback end-to-end test.

Real headphone identity stability, Bluetooth/USB/AirPlay transitions, audible EQ
changes during playback/mixing, physical haptics, VoiceOver reading, battery/frame
measurements and iOS PiP/background behavior still require an iPhone. CI or
Simulator success does not establish those physical-device results. Existing
Apple translation model/language availability and cold-start constraints remain.
