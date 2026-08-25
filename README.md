English | [中文](./README_zh.md)

# FocusTrafficLight

A macOS menu bar app that automatically manages window focus recovery.

## Features

- **Keyboard-triggered**: Listens for explicit `Cmd+W` (close window) and `Cmd+M` (minimize window)
- **Traffic light clicks**: Recognizes real clicks on the red close / yellow minimize buttons, including wrapped button hierarchies
- **App hide focus**: Apps with their own hide shortcuts (WeChat, QQ, Feishu...) focus the next window after hiding
- **AX close/minimize fallback**: Window destroyed / minimized notifications are accepted only while the eventing app is frontmost, so background apps cannot steal focus
- **Single 50ms check**: After a trigger, the target window is checked exactly once; if it is still on screen (for example closing a browser tab), recovery is skipped without polling
- **Topmost visible window selection**: After the target window disappears, activates the first `layer 0` window in the current Space, excluding this app's own windows
- **Broad compatibility**: No AX role, size, or activation-policy heuristics, so v2rayN and Keynote save panels work normally
- **Near-zero idle CPU**: All listeners are event-driven; there is no background polling
- **Menu Bar Control**: Clean menu bar interface with one-click toggle

## How It Works

1. An explicit action is detected: `Cmd+W`, `Cmd+M`, a traffic light click, or an app hide.
2. The target window's `CGWindowID` is captured from the keyboard event, the AX focused window, or the AX element.
3. 50ms later the window is checked once against `CGWindowList(.optionOnScreenOnly)`.
4. If it is gone, the topmost visible window in the current Space is activated; if it is still visible, nothing happens.

Additional guards:

- `Cmd+H` is recorded, and hide notifications arriving within 0.5s are ignored so the system's own hide behavior is not doubled.
- Rapid triggers are collapsed by a 0.2s debounce, and auto-repeat key events are ignored.
- AX destroyed / miniaturized notifications from a background app are filtered out by PID.

## Design Notes

- Focus is only moved after an explicit close/minimize/hide action or a frontmost-app window destruction/minimization event
- Candidates are selected directly from `CGWindowList` z-order: `layer 0`, current Space, not this process
- No AX window role matching is required, so Keynote save panels and v2rayN windows work normally
- Trigger-to-focus is a single 50ms check with no polling; if the target window ID is unavailable it is treated as already gone

## Requirements

- macOS (tested on macOS 15, others untested)
- Accessibility permission required

## Installation

1. Download the latest `FocusTrafficLight_vX.Y.Z.zip` from Releases
2. Extract and drag to Applications folder
3. Grant Accessibility permission on first launch, **restart the app after granting permission**

## Usage

- Click menu bar icon to view status
- "Enable Focus" toggle to enable/disable focus recovery
- "Launch at Login" to set startup behavior

## Privacy

This app requires Accessibility permission to read window state. The permission is only used for focus management. No user data is collected or transmitted.
