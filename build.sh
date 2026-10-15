#!/bin/zsh
# Build BatteryBar.app into ~/Applications
set -e
cd "$(dirname "$0")"
APP="$HOME/Applications/BatteryBar.app"
MIN_VERSION="$(/usr/libexec/PlistBuddy -c 'Print :LSMinimumSystemVersion' Info.plist)"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
swiftc -O -target "$(uname -m)-apple-macos$MIN_VERSION" \
  -o "$APP/Contents/MacOS/BatteryBar" main.swift \
  -framework AppKit -framework IOKit -framework ServiceManagement
cp Info.plist "$APP/Contents/Info.plist"
cp Resources/BatteryBar.icns "$APP/Contents/Resources/"
codesign --force -s - "$APP"
echo "Built $APP"
