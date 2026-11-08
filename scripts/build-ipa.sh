#!/bin/bash
# Clean, signed IPA build (iPhone app + embedded Watch app + Live Activity extension).
#
# Every run stamps a NEW build number (YYMMDDHHMM) on all three targets. Without that, each IPA
# reported the same version (1.0, build 1), so iOS / sideloading tools could treat a new IPA as
# "the same app" and keep the old Watch or widget copy — a mix of old and new behavior.
#
# Usage: scripts/build-ipa.sh [output.ipa]   (default: ~/Downloads/Drive Tracker - Bethel Signed.ipa)
set -euo pipefail
cd "$(dirname "$0")/.."

OUT="${1:-$HOME/Downloads/Drive Tracker - Bethel Signed.ipa}"
BUILD_NUMBER="$(date +%y%m%d%H%M)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

[ -f Secrets.xcconfig ] || { echo "Secrets.xcconfig missing (copy Secrets.xcconfig.example)"; exit 1; }

echo "Build number $BUILD_NUMBER — clean archive in a fresh derived-data folder…"
xcodebuild clean archive -scheme "Driving app" -configuration Release \
  -destination 'generic/platform=iOS' DEVELOPMENT_TEAM=THW3L89YM6 CODE_SIGN_STYLE=Automatic \
  -allowProvisioningUpdates -derivedDataPath "$WORK/dd" -archivePath "$WORK/arch.xcarchive" \
  CURRENT_PROJECT_VERSION="$BUILD_NUMBER" | grep -E "error:|ARCHIVE (SUCCEEDED|FAILED)" || true
[ -d "$WORK/arch.xcarchive" ] || { echo "Archive failed"; exit 1; }

xcodebuild -exportArchive -archivePath "$WORK/arch.xcarchive" -exportOptionsPlist scripts/ExportOptions.plist \
  -exportPath "$WORK/export" -allowProvisioningUpdates | grep -E "error:|EXPORT (SUCCEEDED|FAILED)" || true
[ -f "$WORK/export/Driving app.ipa" ] || { echo "Export failed"; exit 1; }

cp "$WORK/export/Driving app.ipa" "$OUT"

# Verify what actually shipped: same build number + minimum OS on every embedded bundle.
CHECK="$(mktemp -d)"; unzip -q "$OUT" -d "$CHECK"
for p in "$CHECK"/Payload/*.app "$CHECK"/Payload/*.app/Watch/*.app "$CHECK"/Payload/*.app/PlugIns/*.appex; do
  echo "$(basename "$p"): build=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$p/Info.plist") min=$(/usr/libexec/PlistBuddy -c 'Print :MinimumOSVersion' "$p/Info.plist")"
done
rm -rf "$CHECK"
ls -l "$OUT"
