# FocusTrafficLight - macOS Window Focus Utility

## 1. Project Overview

- **Project Name**: FocusTrafficLight
- **Bundle Identifier**: com.focustrafficlight.app
- **Core Functionality**: A lightweight menu-bar macOS app that focuses the next logical window after an explicit user action closes, minimizes, or hides the current window. Target selection uses the topmost visible window in the current Space, without requiring AX window metadata.
- **Target Users**: Power users who want window focus behavior similar to Windows
- **macOS Version Support**: macOS 27.0+

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
- AX `kAXApplicationHiddenNotification` / `AXUIElementDestroyed` is accepted regardless of frontmost state, except when it arrives within 0.5s of `Cmd+H`
- App-hide triggers carry no window ID: the accessibility element is destroyed before the notification arrives, so the engine waits on whether the source app still owns a visible window instead
- A 0.2s debounce collapses rapid triggers; auto-repeat key events are ignored
- The target window is captured as a `CGWindowID` from the keyboard event window (only when that window really belongs to the frontmost app) or from the frontmost window of the source app; when unavailable it is treated as already gone
- The AX-notification path applies the same 0.2s debounce as the keyboard path, so a burst of desktop destroy/recreate events collapses into one check

#### 3. Focus Logic (Priority: Critical)
- **Trigger**: Explicit close, minimize, or app hide — always a user action
- **Timing**: focus moves 50ms after the trigger, matching V4
- **No dismissal verification**: V4 checked, once, 50ms after the trigger, using the private `AXCGWindowID` attribute. macOS 27 removed that attribute, so the lookup always came back empty and the check always concluded "window gone" — V4 on macOS 27 was therefore focusing unconditionally after 50ms, which is what this version reproduces. A real check cannot be both fast and correct: the window stays on screen until its animation ends (~140ms for a Finder close, ~225ms for Chrome, ~660ms for a minimize)
- **Instant filters** (no timing involved):
  - acting on one of several windows that leaves another on the same display does nothing, since focus does not need to move
  - the source app is never the candidate — focus is moving away from it
  - a next window on the same display is preferred, so acting on one screen does not push focus to another
- **Selection Algorithm**:
  1. Get all windows visible on the active Space in front-to-back z-order
  2. Prefer `layer 0` on the acted-on window's display, excluding this process and the source app
  3. Focus via the activation strategy below
- No AX role, size, or activation-policy heuristics, so v2rayN and Keynote save panels are both recognized

#### 3a. Window Ordering and Space Filtering (Priority: Critical)
- `NSWindow.windowNumbers(options: [.allApplications])` returns visible windows on the **active Space** in z-order; this is the public API that replaces the private `CGSSpaceCopyCurrent` / `CGSCopySpacesForWindow` symbols used before v5.0.0
- `CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements])` supplies owner PID, layer and bounds for those window numbers. These keys do not require Screen Recording; window titles do, so no title is ever read
- If `windowNumbers` returns nothing the engine falls back to the CG list and logs that the result is not Space-filtered, rather than failing silently

#### 3b. Activation Strategy (Priority: Critical)
- Attempted in order, each step verified against `NSWorkspace.shared.frontmostApplication` and logged:
  1. `kAXFrontmostAttribute` on the target app (plus `kAXRaiseAction` / `kAXMainAttribute` on the matching window)
  2. `NSRunningApplication.activate(from:options:)` — cooperative activation, macOS 14+
  3. `NSRunningApplication.activate(options: [.activateAllWindows])`
- `NSApplicationActivateIgnoringOtherApps` is not used: it is documented as having no effect since macOS 14
- The target window element is matched to the chosen `CGWindowID` by comparing `kAXPositionAttribute` / `kAXSizeAttribute` with the window bounds, because macOS 27 no longer provides `AXCGWindowID`

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
  - `FocusRecoveryEngine` - Recovery decision: did the target window actually leave the screen?
  - `WindowOrderService` - Window identity, z-order and Space filtering (public API only)
  - `ActivationService` - Ordered, verified activation of the next app
  - `AXGeometry` - Shared AX attribute / frame helpers
  - `AccessibilityHelper` - Permission checking and settings deep links

### Edge Cases & Error Handling
1. **No accessibility permission**: Logged on startup and before every check; the app prompts on launch and opens System Settings if declined
2. **Target window still visible (tab close / blank window)**: Skip recovery immediately
3. **No valid windows to focus**: Do nothing
4. **Background AX noise**: Destroyed/miniaturized notifications from non-frontmost apps are filtered by PID
5. **Rapid close/minimize events**: 0.2s debounce on both the keyboard and AX-notification paths, plus a supersede token so a newer trigger cancels an in-flight re-check
6. **Slow window teardown**: the re-check gives the close animation up to 800ms to finish; if the window is still there the trigger is abandoned
7. **Finder desktop churn**: Finder destroys and recreates its desktop element during Quick Look and desktop interactions; these are suppressed when Finder has no standard window
8. **Activation refused**: Each activation step is verified against the frontmost app and logged, so a refusal is visible instead of silent

## 4. Technical Specification

### Dependencies
- **None** - Pure Apple frameworks only

### Frameworks Used
- `AppKit` - UI, menu bar, `NSWindow.windowNumbers`, `NSRunningApplication`
- `ApplicationServices` - AXUIElement / AXObserver APIs
- `CoreGraphics` - CGWindowList / CGWindow APIs
- `IOKit` - `IOHIDCheckAccess` for Input Monitoring status
- `ServiceManagement` - SMAppService for launch at login

### Private API Policy
- **None.** v5.0.0 uses only public API. Earlier versions called the private symbols `CGSSpaceCopyCurrent` and `CGSCopySpacesForWindow` (removed in macOS 27) and the private AX attribute `AXCGWindowID` (removed in macOS 27).

### Signing
- A stable local signing identity (`Focus TrafficLight Local Signing`) is used instead of ad-hoc signing. TCC binds the Accessibility grant to the designated requirement, which for ad-hoc signing is the binary hash — so every rebuild invalidated the grant. With a certificate-rooted requirement the grant survives rebuilds.

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
│   ├── WindowOrderService.swift
│   ├── ActivationService.swift
│   ├── AXGeometry.swift
│   ├── AppLogger.swift
│   └── AccessibilityHelper.swift
├── Resources/
│   └── Info.plist
└── FocusTrafficLight.entitlements
```

## 5. Version History

### v5.0.0 - macOS 27 Support (2026-09-17)
- Private `AXCGWindowID` attribute is gone on macOS 27, leaving the target window unknown and the "did it disappear" check permanently short-circuited; window identity now comes from `NSWindow.windowNumbers` plus geometric bounds matching
- Private `CGSSpaceCopyCurrent` / `CGSCopySpacesForWindow` symbols are gone on macOS 27, so Space filtering had silently degraded; it now comes from the public active-Space z-order list
- Finder desktop / Quick Look suppression no longer reads `kCGWindowName` (empty without Screen Recording); it checks whether Finder still has a standard window, and the AX path gained the debounce it was missing
- Activation no longer uses the no-op `activateIgnoringOtherApps` flag; it runs an ordered, verified strategy and logs the result
- Key pipeline logs moved to `notice` so they persist and are visible to `log show`
- Signed with a stable local certificate so the Accessibility grant survives rebuilds
- Minimum system version raised to macOS 27.0

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
