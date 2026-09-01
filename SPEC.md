# FocusTrafficLight - macOS Window Focus Utility

## 1. Project Overview

- **Project Name**: FocusTrafficLight
- **Bundle Identifier**: com.focustrafficlight.app
- **Core Functionality**: A lightweight menu-bar macOS app that focuses the next logical window after an explicit user action closes, minimizes, or hides the current window. Target selection uses the topmost visible window in the current Space, without requiring AX window metadata.
- **Target Users**: Power users who want window focus behavior similar to Windows
- **macOS Version Support**: macOS 13.0+ (Ventura and later)

## 2. UI/UX Specification

### Window Structure
- **No main window** - Runs as background app (LSUIElement = true)
- **Menu Bar Item**: NSStatusItem with system SF Symbol icon
- **Menu**: NSMenu with three options

### Visual Design

#### Menu Bar Icon
- SF Symbol: `chevron.left.forwardslash.chevron.right` (represents traffic lights)
- Size: 18x18 points
- Color: Template image (adapts to light/dark mode)

#### Menu Structure
```
[✓] Enabled
[ ] Launch at Login
---
Quit
```

#### Typography
- System default menu font (SF Pro)

#### Colors
- Menu bar icon: Template (system adaptive)
- Menu items: System default

### Views & Components
- `NSStatusItem` - Menu bar presence
- `NSMenu` - Dropdown menu
- `NSMenuItem` - Individual menu options

## 3. Functionality Specification

### Core Features

#### 1. Trigger Monitoring (Priority: Critical)
- Global keyboard monitor for `Cmd+W` (close window) and `Cmd+M` (minimize window)
- Mouse event tap for real clicks on red close / yellow minimize buttons
- AX notifications for apps with their own hide shortcuts (WeChat, QQ, Feishu...)
- `Cmd+H` is suppressed so the system's own hide behavior is not doubled

#### 2. Trigger Recognition (Priority: Critical)
- Keyboard and traffic light clicks capture the frontmost app and its target window at event time
- AX `kAXUIElementDestroyedNotification` / `kAXWindowMiniaturizedNotification` are accepted only when the event PID matches the current frontmost app, acting as a fallback without letting background apps steal focus
- AX `kAXApplicationHiddenNotification` is accepted regardless of frontmost state, except when it arrives within 0.5s of `Cmd+H` (the system handles that case itself)
- A 0.2s debounce collapses rapid triggers; auto-repeat key events are ignored
- The target window is captured as a `CGWindowID` from the keyboard event window, the AX focused window, or the AX element; when unavailable it is treated as already gone

#### 3. Focus Logic (Priority: Critical)
- **Trigger**: Explicit close, minimize, or app hide
- **Settle**: 50ms after the trigger, then a single check that the target window has left the screen
- **Skip**: If the target window is still visible at the check (browser tab close, blank window, slow animation), recovery is skipped without polling or waiting
- **Selection Algorithm**:
  1. Get all windows in Z-order (front to back)
  2. Filter: `layer 0`, current Space, owner is not this process
  3. Focus: `NSRunningApplication.activate(activateIgnoringOtherApps)`
- No AX role, size, or activation-policy heuristics, so v2rayN and Keynote save panels are both recognized
- No background polling: the engine performs exactly one check per trigger and returns

#### 4. Accessibility Permission Handling (Priority: Critical)
- Check permission status on launch
- Prompt user to grant Accessibility permission if not granted
- Show alert with instructions to System Preferences

#### 5. Launch at Login (Priority: Medium)
- Use `SMAppService` for modern launch-at-login (macOS 13+)
- Menu item shows current state with checkmark

### User Interactions
1. Click menu bar icon → Shows menu
2. Toggle "Enabled" → Enables/disables window focus behavior
3. Toggle "Launch at Login" → Enables/disables login item
4. Click "Quit" → Terminates application

### Data Handling
- **UserDefaults**: Stores enabled state and launch-at-login preference
- No external API calls
- No persistent logging

### Architecture Pattern
- **Pattern**: Simple AppDelegate-based architecture (suitable for menu-bar app)
- **Components**:
  - `AppDelegate` - Main application controller
  - `WindowManager` - Handles window focus logic
  - `FocusEventMonitor` - Keyboard / mouse / hide trigger sources
  - `FocusRecoveryEngine` - Target window discovery and activation
  - `AccessibilityHelper` - Permission checking and AX utilities

### Edge Cases & Error Handling
1. **No accessibility permission**: Show alert, open System Preferences
2. **Target window still visible (tab close / blank window)**: Skip recovery immediately
3. **No valid windows to focus**: Do nothing
4. **Background AX noise**: Destroyed/miniaturized notifications from non-frontmost apps are filtered by PID
5. **Rapid close/minimize events**: 0.2s debounce prevents rapid switching
6. **Slow window teardown**: If the window is still on screen at the 50ms check, the trigger is abandoned and macOS handles focus itself

## 4. Technical Specification

### Dependencies
- **None** - Pure Apple frameworks only

### Frameworks Used
- `AppKit` - UI and menu bar
- `ApplicationServices` - AXUIElement APIs
- `CoreGraphics` - CGWindowList / CGWindow APIs
- `ServiceManagement` - SMAppService for launch at login
- `Cocoa` - Foundation and AppKit

### Required Info.plist Keys
```xml
<key>LSUIElement</key>
<true/>
<key>NSAppleEventsUsageDescription</key>
<string>FocusTrafficLight needs accessibility access to manage window focus.</string>
```

### Entitlements
- App Sandbox: NO (requires accessibility access)
- Hardened Runtime: NO (local ad-hoc signed build)

### Asset Requirements
- None (uses SF Symbols)

### File Structure
```
FocusTrafficLight/
├── project.yml
├── SPEC.md
├── README.md
├── README_zh.md
├── CHANGELOG.md
├── Sources/
│   ├── main.swift
│   ├── AppDelegate.swift
│   ├── WindowManager.swift
│   ├── FocusEventMonitor.swift
│   ├── FocusRecoveryEngine.swift
│   ├── AppLogger.swift
│   └── AccessibilityHelper.swift
├── Resources/
│   └── Info.plist
└── FocusTrafficLight.entitlements
```

## 5. Version History

### v4.0.4 - Hidden Notification Validation (2026-09-01)
- `kAXApplicationHiddenNotification` is only honored when the app is actually hidden
- Right-click menus and selection panels that briefly disappear no longer trigger focus recovery
- A window hidden event is skipped when the source app still has visible windows
- App-specific hide shortcuts (WeChat, QQ, Feishu) continue to focus the next window

### v4.0.3 - Desktop Quick Look Suppression (2026-08-28)
- Desktop Quick Look emits window destroy/minimize AX events from Finder before the preview panel appears
- Finder-originated destroy/minimize notifications are now skipped while Finder is frontmost
- Quick Look open/close no longer triggers focus recovery; explicit close/minimize/hide paths are unchanged

### v4.0.2 - Single 50ms Check (2026-08-25)
- Replaced the 1s polling loop with a single 50ms on-screen check
- Tab-close scenarios (target window still visible) no longer block or wait
- Window gone means focus the next topmost window; otherwise skip immediately

### v4.0.1 - Simplified Topmost-Window Selection (2026-08-25)
- Fixed: apps with `activationPolicy == .accessory` but real windows (e.g. v2rayN) were skipped
- Removed size and activation-policy heuristics from target discovery
- Target is now simply the first `layer 0` window in the current Space not owned by this process
- Keynote save panels remain supported without AX window matching

### v4.0.0 - Keyboard-Triggered Focus Recovery (2026-08-24)
- Replaced broad AXObserver lifecycle monitoring with explicit close/minimize triggers
- Added traffic light click recognition and app hide notifications
- Focus recovery only runs after the triggered window actually disappears
- Removed Quick Look, Finder preview, launch grace, and multi-guard heuristics

### v2.1.2 - 空间过滤 (2026-05-16)
- 新增窗口空间过滤功能，只识别当前 Space 中的窗口
- 使用 CGSSpaceCopyCurrent 和 CGSCopySpacesForWindow 获取当前 Space 并过滤窗口
- 解决多 Space 环境下焦点误切换到其他 Space 窗口的问题

### v2.1.1 - 修复窗口最小化/隐藏行为
- 修复窗口最小化（minimize）触发焦点切换逻辑
- 移除窗口隐藏（hide/Cmd+H）时的焦点切换干预，由 macOS 自动处理
- 优化窗口销毁检测，减少竞态条件

### v2.1.1 - 权限与基础功能完善第一版本
- 权限与基础功能完善第一版本
- 优化辅助功能权限检查流程
- 实现窗口焦点智能管理
- 支持文件对话框（NSOpenPanel/NSSavePanel）识别
- 支持应用隐藏（Hiding）场景的焦点切换
- 添加 Focus Vacuum Detection 防止误触发
