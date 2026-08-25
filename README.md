English | [中文](./README_zh.md)

# FocusTrafficLight

A macOS menu bar app that automatically manages window focus recovery.

## Features

- **Automatic Focus Recovery**: After closing, minimizing, or hiding a window, automatically focuses on the topmost visible window
- **Close and Minimize Triggers**: Works with `Cmd+W`, `Cmd+M`, and clicking the red close or yellow minimize traffic light buttons
- **App Hide Support**: WeChat, QQ, Feishu, and other apps with their own hide shortcuts focus the next window after hiding
- **Broad Compatibility**: Works with regular apps and non-standard windows such as v2rayN and Keynote save panels
- **Menu Bar Control**: Clean menu bar interface with one-click toggle

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

This app requires Accessibility permission to monitor window events. The permission is only used for focus management. No user data is collected or transmitted.
