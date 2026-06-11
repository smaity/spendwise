#!/bin/bash
# Build SpendWise and deploy it to a connected iPhone. Run on your Mac from this folder:
#   ./build-release.sh [TEAM_ID] [DEVICE_ID]
#
# TEAM_ID   (optional) your Apple Developer Team ID. Find it in Xcode → Settings →
#           Accounts → your team, or at developer.apple.com/account. If omitted, the
#           project's configured team is used.
# DEVICE_ID (optional) target device UUID. If omitted, the first connected device is
#           used. List devices with: xcrun devicectl list devices
#
# Tip: copy deploy.env.example to deploy.env and set TEAM_ID / DEVICE_ID there, then
# just run ./build-release.sh with no args. deploy.env is git-ignored. Command-line
# args override the file; the file overrides nothing else.
#
# The script archives a Release build, exports a device-signed .ipa, then installs and
# launches it on the device. Unlock the iPhone and trust this Mac before running.
set -euo pipefail
cd "$(dirname "$0")"

BUNDLE_ID="com.eduquizacademy.spendwise"

# Load local defaults (TEAM_ID / DEVICE_ID) if present. Git-ignored; see deploy.env.example.
# Command-line args (below) take precedence over the file.
if [ -f deploy.env ]; then
  # shellcheck disable=SC1091
  source ./deploy.env
fi

TEAM="${1:-${TEAM_ID:-}}"
DEVICE="${2:-${DEVICE_ID:-}}"

EXTRA=()
[ -n "$TEAM" ] && EXTRA+=("DEVELOPMENT_TEAM=$TEAM")

# Resolve the target device: explicit arg/env, else the first connected one.
if [ -z "$DEVICE" ]; then
  echo "==> Finding a connected device..."
  DEVICE=$(xcrun devicectl list devices 2>/dev/null \
    | grep -iE 'available' \
    | grep -oiE '[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}' \
    | head -1)
  if [ -z "$DEVICE" ]; then
    echo "!! No connected device found. Plug in your iPhone, unlock it, and trust this Mac." >&2
    echo "   List devices with: xcrun devicectl list devices" >&2
    exit 1
  fi
fi
echo "==> Target device: $DEVICE"

echo "==> Archiving (Release)..."
xcodebuild -project SpendWise.xcodeproj \
  -scheme SpendWise \
  -configuration Release \
  -destination 'generic/platform=iOS' \
  -archivePath build/SpendWise.xcarchive \
  archive "${EXTRA[@]}"

echo "==> Exporting .ipa..."
rm -rf build/export
xcodebuild -exportArchive \
  -archivePath build/SpendWise.xcarchive \
  -exportOptionsPlist ExportOptions.plist \
  -exportPath build/export

IPA=$(ls build/export/*.ipa | head -1)
echo "==> Built: $IPA"

echo "==> Installing on device..."
xcrun devicectl device install app --device "$DEVICE" "$IPA"

echo "==> Launching..."
xcrun devicectl device process launch --device "$DEVICE" "$BUNDLE_ID" || \
  echo "   (Launch skipped — open SpendWise from the Home Screen.)"

echo "==> Done. SpendWise is installed on your iPhone."
