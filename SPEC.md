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
- Global keyboard monitor for `Cmd+W` (close window), `Cmd+M` (minimize window) and `Cmd+H` (hide app)
- Mouse event tap for real clicks on red close / yellow minimize buttons
- AX notifications for apps with their own hide shortcuts (WeChat, QQ, Feishu...)

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
- **Timing**: every trigger starts checking immediately; there is no settle delay. An app hide used to wait 50ms, on the theory that its notification could arrive before the app's accessibility window count had settled — but a count that has not settled reads as the older, higher value, which the poll loop already treats as "keep waiting" and re-checks 15ms later. The delay therefore bought at most a poll or two while always spending 50ms, and it worked against the baseline capture, which must run as early as possible to record the pre-dismissal count
- **Verify, then focus**: recovery waits for evidence that the acted-on window actually went away. This is required: without it, closing a browser tab (the window is still there) would steal focus, and a minimize would move focus mid-animation
- **Why the evidence is never instant**: the window stays on screen until its animation ends — measured on macOS 27 at ~140ms for a Finder close, ~225ms for Chrome, ~660ms for a minimize. The wait is at the signal's own speed, not the bound's: a 15ms poll interval means focus moves within one interval of the signal
- **The bound only bounds non-dismissals**: a closing tab never produces the signal, so it waits out the 1.0s bound and is then skipped. Since no focus change was going to happen, that wait is invisible. Sizing the bound generously therefore costs nothing in perceived speed
- **Evidence per dismissal kind**:
  - **close** — the window leaves the app's accessibility window list (~140–225ms), which is well before it leaves the on-screen list, so that list decides
  - **minimize** — the minimized flag on the window (`kAXMinimizedAttribute`), which flips at ~120–360ms and is the earliest reliable signal; the on-screen list only clears at ~725–940ms and is jittery enough to overrun the bound. When the acted-on window is unknown, any minimized window of the app is used; the on-screen list is the last resort. A minimize is never decided from the app's window count, which it does not change
    - `Cmd+M` is an *application* command, not a window operation: the system asks the app to minimize, and an app that never wired the command up ignores it outright. Parallels Desktop does exactly that — measured, its VM window is untouched 4s after `Cmd+M` with this app not running, while `kAXMinimizedAttribute` on that window is settable and writing it minimizes it. Since such a minimize produces no signal at all, waiting out the bound only burns polls and then skips recovery
    - The fallback: once the window has had `minimizeFallbackDelay` (0.12s) and no signal has appeared, the engine writes `kAXMinimizedAttribute` itself, once per trigger, and keeps watching the same window. Sizing it near the fast end matters two ways — an app that handles the key has already flipped the flag (measured at 15ms for TextEdit, Chrome and Finder), so it is never touched, while an app that never will does not sit in the poll loop. Recovery logic is unchanged; only the action is supplied
    - Measured on the fallback path: Parallels Desktop confirmed at 150ms and focused the next window; TextEdit, Chrome and Finder confirmed at 15ms with the fallback never firing
  - **hide** — no window ID is available (the element is destroyed before the notification), so the app's *window count* decides and nothing else. It drops as soon as the window is given up (~140ms for WeChat), whereas the on-screen list lags until the hide/close animation ends (~400ms), so waiting on the count roughly triples the responsiveness. A count that merely stays the same (a dismissed menu or panel) never fires, which is what keeps the false positives out without needing the on-screen signal as well
- **Confirmation**: two consecutive agreeing polls, so a single transient read cannot move focus while the window is still on screen
- **Instant filters** (no timing involved): acting on one of several windows that leaves another on the same display does nothing; the source app is never the candidate; a next window on the same display is preferred
- **The "still has a window" test is asked twice**: once at trigger time, and again after the dismissal is confirmed but before focus actually moves. Apps do not answer it consistently during the close — some briefly drop the *surviving* window from the on-screen list while another of their windows goes away (Terminal; Finder reported earlier). The window is alive and correctly framed, just unreported for a moment. With only one window left there is nothing else in the list to mask that gap, so the trigger-time read concludes the app has no windows and hands focus away; with three or more, some window usually escapes the gap, which is why the failure looks count-dependent. It is a race, not a rule. By the time the dismissal is confirmed (15–150ms later) the app has settled, so the second read sees the surviving window and focus is correctly held. When the app really did close its last window both reads agree, so normal recovery is unchanged. Costs one extra window-list query
- **Selection Algorithm**:
  1. Get all windows visible on the active Space in front-to-back z-order
  2. Prefer `layer 0` on the acted-on window's display, excluding this process and the source app
  3. Focus via the activation strategy below

#### 3a. Window Ordering and Space Filtering (Priority: Critical)
- `NSWindow.windowNumbers(options: [.allApplications])` returns visible windows on the **active Space** in z-order; this is the public API that replaces the private `CGSSpaceCopyCurrent` / `CGSCopySpacesForWindow` symbols used before v5.0.0
- `CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements])` supplies owner PID, layer and bounds for those window numbers. These keys do not require Screen Recording; window titles do, so no title is ever read
- If `windowNumbers` returns nothing the engine falls back to the CG list and logs that the result is not Space-filtered, rather than failing silently

#### 3b. Activation Strategy (Priority: Critical)
- **Window-scoped activation**, matching what a user click does: the target window is first made the app's main/key window (`kAXRaiseAction` + `kAXMainAttribute` + `kAXFocusedAttribute`), then the app is activated with `activate(options: [])`. Per the header, activation without `.activateAllWindows` "brings only the main and key windows forward", so the app's windows on other displays are not raised
- Strategies are attempted in order, each verified against `NSWorkspace.shared.frontmostApplication` and logged:
  1. `window + activate(options:[])` — the window-scoped path above
  2. `kAXFrontmostAttribute` on the target app
  3. `NSRunningApplication.activate(from:options:)` — cooperative activation, macOS 14+
  4. `NSRunningApplication.activate(options: [.activateAllWindows])` — last resort only
- `.activateAllWindows` raises *all* of the app's windows on *every* display, which is what made the same app's window flash on the display the user was not working on. It is therefore not the normal path
- `NSApplicationActivateIgnoringOtherApps` is not used: it is documented as having no effect since macOS 14
- The target window element is matched to the chosen `CGWindowID` by comparing `kAXPositionAttribute` / `kAXSizeAttribute` with the window bounds, because macOS 27 no longer provides `AXCGWindowID`
- A display whose window order changes during activation is logged, with the strategy that caused it, so any cross-display disturbance is visible rather than silent

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

### v5.0.4 - Focus No Longer Escapes an App That Still Has a Window (2026-11-02)
- Closing one of an app's last two windows used to hand focus to another app instead of leaving it with the surviving window. Reported on Terminal, and earlier on Finder
- The cause was the sampling moment, not the number of displays: the "does this app still have a window here" test ran once at trigger time, and during a close some apps briefly drop the *surviving* window from the on-screen list — alive and correctly framed, simply not reported for that instant. With one window left nothing else in the list masks the gap, so the app was judged to have no windows; with three or more windows one usually escapes the gap, which is why the failure looked count-dependent. It is a race, and the count only changes how often it is hit
- The test is now asked a second time after the dismissal is confirmed and before focus moves. 15–150ms have passed by then and the app has settled, so the surviving window is back in the list and focus is correctly held. When the app did close its last window both reads agree, so normal recovery is unchanged
- The problem dates from v5.0.0 (`e1cff13` added the close-path display test), not from an OS update. v4 never ran this test on `Cmd+W` at all, so it always focused another app after a close
- A first attribution to dual displays and the `onDisplay:` filter was measured and ruled out: with a single display that parameter has no effect, so changing it could not have fixed this

### v5.0.3 - Minimize Fallback for Apps That Ignore Cmd+M (2026-10-30)
- `Cmd+M` is an application command, so an app that never implemented it ignores the keystroke completely and no signal of any kind appears. Parallels Desktop does this: measured with this app not running, its VM window was untouched 4s after `Cmd+M`, while `kAXMinimizedAttribute` on the same window is settable and writing it minimizes it
- Such a minimize used to wait out the 1.0s bound and then skip recovery, so focus never moved. Now, once the window has had 0.12s without a signal, the engine writes `kAXMinimizedAttribute` itself — once per trigger, by matching window frame — and keeps watching the same window
- The delay is sized so an app that handles the key itself is never touched: the flag has already flipped by then (measured 15ms on TextEdit, Chrome and Finder). Recovery logic is unchanged; only the action is supplied, and the same evidence is still required before focus moves
- Measured: Parallels Desktop confirmed at 150ms then focused the next window; TextEdit, Chrome and Finder confirmed at 15ms with the fallback never firing

### v5.0.2 - Cmd+H Hide Trigger (2026-10-14)
- `Cmd+H` is now a focus trigger, handled like `Cmd+W` / `Cmd+M`. macOS performs the hide but does not move focus to the next window, so hiding the frontmost app used to leave focus nowhere; recovery now focuses the next window, scoped to the same display
- A `Cmd+H` hide is confirmed from the app's `isHidden` flag rather than the accessibility window count: some apps (TextEdit measured) keep their windows in the accessibility list while hidden, so the count test never fires and would time out. The flag flips within ~60ms
- The `kAXApplicationHiddenNotification` that `Cmd+H` also produces is de-duplicated by keypress time (0.5s) so the two sources do not trigger twice

### v5.0.1 - Close Path and Dual-Display Behaviour (2026-09-18)
- The close decision no longer conflates an empty accessibility window list with a failed read; empty means the acted-on window cannot be present, while a failed read falls through to the on-screen list. This removes the slow path from "closed the app's last window" (measured: Finder 106-118ms, System Settings 135-149ms, Chrome 256-273ms with no timeouts; was 270ms median with 19% timing out)
- A close whose window ID is unknown decides from a drop in the app's window count instead of requiring the list to become empty, and falls back to the on-screen list when the baseline count could not be read
- The window-count baseline is read only for the kinds that compare against it (a hide, or a close whose window is unknown); a minimize and a known-window close read other signals and no longer pay for it
- `kAXUIElementDestroyedNotification` is handled as its own trigger kind, separate from an app hide, with a 400ms wait bound instead of 1.2s. It is not necessarily a window — apps destroy child elements routinely (Chrome, Tencent Meeting) and the delivered element is already invalid, so the only test available is whether the app's window count dropped. Roughly a third of these triggers used to sit out the full 1.2s before being correctly dropped
- The app-hide settle delay was removed, and each dismissal logs the signal that proved it, so the fast and slow paths are distinguishable
- Activation is window-scoped (see Activation Strategy), which removes the flash on the other display; a display whose order changes during activation is logged

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
