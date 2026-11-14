# Release identity and unsigned artifacts

The app and widget use the same fixed marketing version, `0.4.0`. Their checked-in
build baseline is `10000`, above the previous released build `3`. The build baseline
also identifies a local Xcode build; Actions injects a higher number without changing
or committing any project file.

For this existing `Build` workflow, the CI build number is:

```text
10000 + github.run_number × 100 + github.run_attempt
```

For example, workflow run 25 attempt 1 is build 12501; rerunning it is build 12502.
A new run has a higher slot than all 99 supported attempts of the preceding run.
Attempt 100 fails explicitly instead of colliding with the next run. Rerunning an old
workflow keeps that old run's identity and does not represent a newer release than a
subsequent workflow run; publish releases from the latest run. If the workflow counter
is ever reset or moved to another repository, increase the checked-in baseline beyond
all released builds before publishing again.

`python3 scripts/build-version.py --run-number 25 --attempt 1` prints the identity.
It checks that both app/widget Debug and Release versions agree. The read-only
`--next-feature-version 0.4.0` helper prints `0.5.0`, and never lowers an existing
release. CI uses the checked-in semantic version rather than automatically changing it.

The original Xcode 27 iOS Release build and unsigned packaging are retained. The
archive is named `Koda-0.4.0-build<build number>.ipa` and uploaded as an Actions artifact
with the same version/build name. Mac Catalyst uses the same identity with a `-mac`
artifact/DMG suffix. Distinct attempts therefore do not overwrite an older artifact.
No Apple ID, certificate, signing secret or new credential is needed.

Before publishing the IPA artifact, CI checks:

- ZIP CRC integrity and safe paths, then extracts that exact IPA.
- Actual app and widget `CFBundleShortVersionString` and `CFBundleVersion`, using both
  plist parsing and Apple's `plutil`/`PlistBuddy` tools.
- Both executable files exist, preserve executable permissions, are Mach-O binaries,
  and contain the arm64 architecture (`file` and `lipo`).
- The expected app/widget identifiers and iOS device platform remain intact.
- Compiled Traditional Chinese strings exist for the app, widget and KodaCore, and
  localized permission descriptions are included.
- The existing native Foundation probe loads Traditional Chinese from the extracted
  IPA for a `zh-Hant-TW` language preference.

`python3 -m unittest discover -s scripts/tests -v` tests version ordering, rerun
identity, mismatched project/IPA versions, corrupt or incomplete IPA contents and
unsafe extraction paths without requiring Xcode. Native builds and resource loading
still require the Actions Apple toolchain. Unit/CI checks do not establish successful
installation or playback on a physical iPhone.
