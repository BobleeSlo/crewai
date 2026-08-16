#!/bin/bash
# Add the Info.plist keys MileLog needs at runtime.
#
# Five privacy usage strings: iOS terminates the app the first time it touches
# location, camera, photo library or motion without them. CFBundleURLTypes:
# without it the milelog:// password-reset link never reaches the app.
#
# None of the strings contain an apostrophe. PlistBuddy treats an apostrophe
# as a quote character inside a -c command, so a lone one fails with
# "Parse Error: Unclosed Quotes" and a pair silently mangles the value.
#
# Safe to run twice — each key is deleted before being re-added.
#
# Usage:  bash tools/fix_info_plist.sh [path/to/Info.plist]

set -u

PB=/usr/libexec/PlistBuddy
PLIST="${1:-MileLog/Info.plist}"

if [ ! -x "$PB" ]; then
  echo "PlistBuddy not found at $PB — this script only runs on macOS."
  exit 1
fi
if [ ! -f "$PLIST" ]; then
  echo "No such file: $PLIST"
  exit 1
fi

cp "$PLIST" "$PLIST.bak"

set_string() {
  $PB -c "Delete :$1" "$PLIST" >/dev/null 2>&1
  $PB -c "Add :$1 string \"$2\"" "$PLIST" || echo "FAILED to set $1"
}

set_string NSLocationWhenInUseUsageDescription \
  "MileLog measures the distance of your trips."
set_string NSLocationAlwaysAndWhenInUseUsageDescription \
  "MileLog records trips in the background so you do not have to start them manually."
set_string NSCameraUsageDescription \
  "Take a photo of a receipt to attach it to a trip."
set_string NSPhotoLibraryUsageDescription \
  "Attach an existing receipt photo to a trip."
set_string NSMotionUsageDescription \
  "Confirms that you are actually driving, so trips are not started by walking."

$PB -c "Delete :CFBundleURLTypes" "$PLIST" >/dev/null 2>&1
$PB -c "Add :CFBundleURLTypes array" "$PLIST"
$PB -c "Add :CFBundleURLTypes:0 dict" "$PLIST"
$PB -c "Add :CFBundleURLTypes:0:CFBundleTypeRole string Editor" "$PLIST"
$PB -c "Add :CFBundleURLTypes:0:CFBundleURLName string com.blisk.milelog" "$PLIST"
$PB -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes array" "$PLIST"
$PB -c "Add :CFBundleURLTypes:0:CFBundleURLSchemes:0 string milelog" "$PLIST"

echo ""
echo "Values now in $PLIST:"
for KEY in UIBackgroundModes SUPABASE_URL SUPABASE_ANON_KEY \
           NSLocationWhenInUseUsageDescription \
           NSLocationAlwaysAndWhenInUseUsageDescription \
           NSCameraUsageDescription NSPhotoLibraryUsageDescription \
           NSMotionUsageDescription; do
  VALUE=$($PB -c "Print :$KEY" "$PLIST" 2>/dev/null | tr '\n' ' ')
  if [ -z "$VALUE" ]; then
    echo "  MISSING  $KEY"
  else
    echo "  $KEY = $VALUE"
  fi
done
echo "  CFBundleURLSchemes:0 = $($PB -c 'Print :CFBundleURLTypes:0:CFBundleURLSchemes:0' "$PLIST" 2>/dev/null)"
echo ""
echo "Backup at $PLIST.bak"
