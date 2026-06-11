#!/bin/bash
# Release build for SpendWise. Run on your Mac from this folder:
#   ./build-release.sh [TEAM_ID]
# Find your Team ID: Xcode → Settings → Accounts → your team, or developer.apple.com/account.
set -e
cd "$(dirname "$0")"

TEAM="${1:-}"
EXTRA=()
[ -n "$TEAM" ] && EXTRA+=("DEVELOPMENT_TEAM=$TEAM")

echo "==> Archiving (Release)..."
xcodebuild -project SpendWise.xcodeproj \
  -scheme SpendWise \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath build/SpendWise.xcarchive \
  archive "${EXTRA[@]}"

echo "==> Exporting .ipa..."
xcodebuild -exportArchive \
  -archivePath build/SpendWise.xcarchive \
  -exportOptionsPlist ExportOptions.plist \
  -exportPath build/

echo "==> Done: $(ls build/*.ipa)"
echo "Install on your iPhone via Xcode (Window → Devices and Simulators → drag the .ipa onto your device)."
