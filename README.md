English | [中文](./README_zh.md)

# FocusTrafficLight

A macOS menu bar app that automatically manages window focus recovery.

![FocusTrafficLight demo: close or minimize a window and focus moves to the next one](./docs/demo.gif)

When you close, minimize, or hide a window, focus automatically moves to the next visible
window — the same way it would if you had picked it yourself, so you never have to reach
for the mouse or `Cmd+Tab` afterwards.

## Features

- **Automatic Focus Recovery**: After closing, minimizing, or hiding a window, automatically focuses on the topmost visible window
- **Close and Minimize Triggers**: Works with `Cmd+W`, `Cmd+M`, and clicking the red close or yellow minimize traffic light buttons
- **Minimize Fallback**: Apps that ignore `Cmd+M` entirely (Parallels Desktop) are minimized on their behalf, so focus still moves
- **App Hide Support**: `Cmd+H` and apps with their own hide shortcuts (WeChat, QQ, Feishu) focus the next window after hiding
- **Broad Compatibility**: Works with regular apps and non-standard windows such as v2rayN and Keynote save panels
- **Menu Bar Control**: Clean menu bar interface with one-click toggle
- **In-App Updates**: Check for a new version from the menu and install it without leaving the app; the version you are running is shown in the menu

## Requirements

- **macOS 27 or later**: use a v27.x release
- **macOS 15 or earlier**: use the **V4 release** — [v4.0.6](https://github.com/xdzgithub/FocusTrafficLight/releases/tag/v4.0.6)
- Accessibility permission required

## Versioning

Versions track the macOS version: **`V<osMajor>.<osMinor>.<fix>`**.

| Your macOS | Download |
| --- | --- |
| 27.2 | V27.2.0 |
| 27.2 (fixes within that release) | V27.2.1, V27.2.2… |
| 27.3 | V27.3.0 |

The app depends on macOS window and Accessibility APIs, and every macOS release can change them — macOS 27 removed several private interfaces the app used to rely on, which is why v5.0.0 was a rewrite. Encoding the system version in the release lets you find the build that matches your OS instead of installing a mismatched one.

## Installation

1. Download `FocusTrafficLight_v27.2.0.dmg` and open it
2. Drag **Focus TrafficLight** into the **Applications** folder next to it
3. Grant Accessibility permission on first launch, **restart the app after granting permission**

## Usage

- Click menu bar icon to view status
- "Enable Focus" toggle to enable/disable focus recovery
- "Launch at Login" to set startup behavior

## Troubleshooting

The app logs its decision path to the unified log. To watch it, run:

```sh
log stream --predicate 'subsystem == "com.focustrafficlight.app"' --level notice
```

Healthy output shows `Permissions — accessibility=true`, `Traffic light mouse tap created`, then
`Focus trigger queued` → `Focus check triggered` → `Focusing: <app>` → `Activate <app> via … frontmost=true`.

## Privacy

This app requires Accessibility permission to monitor window events. The permission is only used for focus management. No user data is collected or transmitted.

## License

Released under the [MIT License](./LICENSE).
