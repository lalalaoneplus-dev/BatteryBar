#!/bin/zsh
# Build BatteryBar.app into ~/Applications
set -e
cd "$(dirname "$0")"
APP="$HOME/Applications/BatteryBar.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
swiftc -O -o "$APP/Contents/MacOS/BatteryBar" main.swift \
  -framework AppKit -framework IOKit -framework ServiceManagement
cp Info.plist "$APP/Contents/Info.plist"
codesign --force -s - "$APP"
echo "Built $APP"
