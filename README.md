# BatteryBar

A macOS menu bar app that shows the battery level of your Bluetooth keyboard and mouse at a glance.

- Reads accessory power sources through IOKit and matches them to attached Bluetooth HID devices.
- Shows each device with an icon and percentage directly in the menu bar; the menu lists every device.
- Refreshes every two minutes.
- **Start at Login** toggle built on `SMAppService`.
- One Swift file, AppKit only, with zero third-party dependencies.

## Build

```sh
./build.sh
```

Builds `BatteryBar.app` into `~/Applications` and ad-hoc signs it.
