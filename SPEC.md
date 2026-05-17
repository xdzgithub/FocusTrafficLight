# FocusTrafficLight - macOS Window Focus Utility

## 1. Project Overview

- **Project Name**: FocusTrafficLight
- **Bundle Identifier**: com.focustrafficlight.app
- **Core Functionality**: A lightweight menu-bar macOS app that automatically focuses the next logical window when a window is closed, minimized, or an app is quit. Only interacts with "standard windows" possessing traffic light controls.
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

#### 1. Window Event Monitoring (Priority: Critical)
- Use `AXObserver` to listen for system-wide accessibility events
- Monitor events:
  - `kAXUIElementDestroyedNotification` - Window closed
  - `kAXWindowMiniaturizedNotification` - Window minimized
  - `kAXUIElementDestroyedNotification` from focused app - App quit

#### 2. Traffic Light Filter (Priority: Critical)
- Only process windows with `kAXCloseButtonAttribute`
- This filters out:
  - Input method candidate windows
  - Tooltips
  - Floating panels
  - Menu windows
  - Other non-standard windows

#### 3. Focus Logic (Priority: Critical)
- **Trigger**: Window closed, minimized, or app quit
- **Debounce**: 150ms wait before attempting focus
- **Selection Algorithm**:
  1. Get all windows in Z-order (front to back)
  2. Filter: Visible, belongs to active app, has close button
  3. Focus: Use `AXUIElementPerformAction(window, kAXRaiseAction)` + `NSRunningApplication.activate()`

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
  - `AccessibilityHelper` - Permission checking and AX utilities

### Edge Cases & Error Handling
1. **No accessibility permission**: Show alert, open System Preferences
2. **No valid windows to focus**: Do nothing
3. **App in background**: Handle gracefully
4. **Rapid close/minimize events**: Debounce prevents rapid switching

## 4. Technical Specification

### Dependencies
- **None** - Pure Apple frameworks only

### Frameworks Used
- `AppKit` - UI and menu bar
- `ApplicationServices` - AXUIElement APIs
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
- Hardened Runtime: YES with accessibility exception

### Asset Requirements
- None (uses SF Symbols)

### File Structure
```
FocusTrafficLight/
├── project.yml
├── SPEC.md
├── Sources/
│   ├── main.swift
│   ├── AppDelegate.swift
│   ├── WindowManager.swift
│   └── AccessibilityHelper.swift
├── Resources/
│   └── Info.plist
└── FocusTrafficLight.entitlements
```

## 5. Version History

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
