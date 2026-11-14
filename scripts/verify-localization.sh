#!/bin/bash
set -euo pipefail

# Bundle lookups follow the host's supported languages. The Swift interpreter is
# an English command-line host, not a bilingual application. Use a real .app host
# so Foundation exercises the same language negotiation as the packaged app.
app_path="$(cd "$1" && pwd)"
probe_root="$(mktemp -d)"
trap 'rm -rf "$probe_root"' EXIT
probe_app="$probe_root/LocalizationProbe.app"
mkdir -p "$probe_app/Contents/MacOS"
cat > "$probe_app/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleIdentifier</key><string>local.koda.localization-probe</string>
<key>CFBundleExecutable</key><string>LocalizationProbe</string>
<key>CFBundlePackageType</key><string>APPL</string>
<key>CFBundleDevelopmentRegion</key><string>en</string>
<key>CFBundleLocalizations</key><array><string>en</string><string>zh-Hant</string></array>
<key>CFBundleAllowMixedLocalizations</key><true/>
</dict></plist>
PLIST
swiftc scripts/verify-localization.swift -o "$probe_app/Contents/MacOS/LocalizationProbe"
"$probe_app/Contents/MacOS/LocalizationProbe" "$app_path" -AppleLanguages '(zh-Hant-TW)'
