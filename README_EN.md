**[中文](./README.md)** | English

# FocusTrafficLight

A macOS menu bar app that automatically manages window focus recovery.

## Features

- **Automatic Focus Recovery**: When a window is closed or minimized, automatically restores focus to the last valid window
- **Smart Guard System**: Four-layer validation ensures focus is only recovered when truly needed
  - Finder Quick Look detection (no interference during file preview)
  - Frontmost app visible window detection (skip for dialog/panel scenarios)
  - Current focused window validity verification
  - Recovery target strict validation
- **Multi-window App Support**: Precise window targeting through bounds matching
- **Menu Bar Control**: Clean menu bar interface with one-click toggle

## Requirements

- macOS 13.0 (Ventura) or later
- Accessibility permission required

## Installation

1. Download `Focus TrafficLight.zip`
2. Extract and drag to Applications folder
3. Grant Accessibility permission on first launch, **restart the app after granting permission**

## Usage

- Click menu bar icon to view status
- "Enable Focus" toggle to enable/disable focus recovery
- "Launch at Login" to set startup behavior

## Privacy

This app requires Accessibility permission to monitor window events. The permission is only used for focus management. No user data is collected or transmitted.
