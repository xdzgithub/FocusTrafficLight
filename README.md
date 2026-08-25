English | [中文](./README_zh.md)

# FocusTrafficLight

A macOS menu bar app that automatically manages window focus recovery.

## Features

- **Keyboard-triggered**: Listens for explicit `Cmd+W` (close window) and `Cmd+M` (minimize window)
- **Traffic light clicks**: Recognizes red close and yellow minimize button clicks, then transfers focus
- **App hide focus**: Apps with their own hide shortcuts (WeChat, QQ, Feishu...) focus the next window after hiding
- **Automatic Focus Recovery**: After the target window disappears, activates the topmost visible window in the current Space
- **Non-standard app support**: Apps like v2rayN that do not expose AX windows but have real windows are recognized
- **Menu Bar Control**: Clean menu bar interface with one-click toggle

## Design Notes

- Focus recovery only triggers on explicit user actions: close, minimize, or hide; generic window destruction events never steal focus
- Candidates are selected directly from `CGWindowList` z-order: `layer 0`, current Space, not this process
- No AX window role matching is required, so Keynote save panels and v2rayN windows work normally
- Trigger-to-focus is a single 50ms check with no polling

## Requirements

- macOS (tested on macOS 15, others untested)
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

This app requires Accessibility permission to read window state. The permission is only used for focus management. No user data is collected or transmitted.
