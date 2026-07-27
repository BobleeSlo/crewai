#!/bin/bash
# Add the Info.plist keys MileLog needs at runtime.
#
# Five privacy usage strings: iOS terminates the app the first time it touches
# location, camera, photo library or motion without them. CFBundleURLTypes:
# without it the milelog:// password-reset link never reaches the app.
#
# Safe to run twice — each key is deleted before being re-added.
#
# Usage:  bash tools/fix_info_plist.sh [path/to/Info.plist]
# Default path is MileLog/Info.plist relative to the repo root.

set -u

PB=/usr/libexec/PlistBuddy
PLIST="${1:-MileLog/Info.plist}"

if [ ! -x "$PB" ]; then
  echo "PlistBuddy not found at $PB — this script only runs on macOS."
  exit 1
fi
if [ ! -f "$PLIST" ]; then
  echo "No such file: $PLIST"
  echo "Pass the path explicitly: bash tools/fix_info_plist.sh path/to/Info.plist"
  exit 1
fi

cp "$PLIST" "$PLIST.bak"

set_string() {
  $PB -c "Delete :$1" "$PLIST" 2>/dev/null
  $PB -c "Add :$1 string $2" "$PLIST"
}

set_string NSLocationWhenInUseUsageDescription \
  "MileLog measures the distance of your trips."
set_string NSLocationAlwaysAndWhenInUseUsageDescription \
  "MileLog records trips in the background so you don't have to."
set_string NSCameraUsageDescription \
  "Take a photo of a receipt to attach it to a trip."
set_string NSPhotoLibraryUsageDescription \
  "Attach an existing receipt photo to a trip."
set_string NSMotionUsageDescription \
  "Confirms you're actually driving, so trips aren't started by walking."

$PB -c "Delete :CFBundleURLTypes" "$PLIST" 2>/dev/null
$PB -c "Add :CFBundleURLTypes array" "$PLIST"
$PB -c "Add :CFBundleURLTypes:0 dict" "$PLIST"
$PB -c "Add :CFBundleURLTypes:0:CFBundleTypeRole string Editor" "$PLIST"
$PB -c "Add :CFBundleURLTypes:0:CFBundleURLName string com.blisk.milelog" "$PLIST"
$PB -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes array" "$PLIST"
$PB -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes:0 string milelog" "$PLIST"

echo ""
echo "Verifying:"
for KEY in UIBackgroundModes CFBundleURLTypes SUPABASE_URL SUPABASE_ANON_KEY \
           NSLocationWhenInUseUsageDescription \
           NSLocationAlwaysAndWhenInUseUsageDescription \
           NSCameraUsageDescription NSPhotoLibraryUsageDescription \
           NSMotionUsageDescription; do
  if $PB -c "Print :$KEY" "$PLIST" >/dev/null 2>&1; then
    echo "  OK      $KEY"
  else
    echo "  MISSING $KEY"
  fi
done
echo ""
echo "Backup at $PLIST.bak"
