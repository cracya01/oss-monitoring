#!/bin/bash
# Build OSSMonitor.app in a system temp dir, install it to /Applications, relaunch.
# The temp build dir is removed afterwards, so only /Applications/OSSMonitor.app remains.
set -euo pipefail
cd "$(dirname "$0")"

WORK=$(mktemp -d -t oss-monitor-build)
trap 'rm -rf "$WORK"' EXIT
APP="$WORK/OSSMonitor.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

swiftc -O -swift-version 5 -parse-as-library \
  -target arm64-apple-macos13.0 \
  OSSMonitor.swift -o "$APP/Contents/MacOS/OSSMonitor"

cp Info.plist "$APP/Contents/"
cp Resources/AppIcon.icns "$APP/Contents/Resources/"
codesign --force --sign - "$APP"

pkill -x OSSMonitor || true
sleep 1
rm -rf /Applications/OSSMonitor.app
ditto "$APP" /Applications/OSSMonitor.app
open /Applications/OSSMonitor.app
echo "Installed /Applications/OSSMonitor.app"
