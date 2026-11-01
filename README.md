# NordBudsMacControl

A macOS menu bar companion for OnePlus Nord Buds 2. It provides battery status, listening mode controls, equalizer presets, a six-band custom EQ, and macOS Control Center buttons for Noise Cancellation, Transparency, and Off.

## Requirements

- macOS 26 or later
- Xcode with the macOS 26 SDK
- OnePlus Nord Buds 2 paired with the Mac over Bluetooth

## Build

Open `NordBudsMacControl.xcodeproj` in Xcode, select the `NordBudsMacControl` scheme, and build the app. The project includes the Control Center extension as an embedded target.

The app communicates with the earbuds over their Bluetooth RFCOMM control channel. macOS system volume adjustment depends on whether the selected audio output exposes a system volume control.
