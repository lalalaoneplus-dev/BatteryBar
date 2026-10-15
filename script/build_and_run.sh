#!/bin/zsh
set -e
cd "$(dirname "$0")/.."
pkill -x BatteryBar || true
./build.sh
open "$HOME/Applications/BatteryBar.app"
sleep 1
pgrep -x BatteryBar >/dev/null
