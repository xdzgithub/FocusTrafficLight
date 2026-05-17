//
//  WindowManager_v3.0.0.swift
//  FocusTrafficLight
//
//  Version: 3.0.0
//  Date: 2026-05-16
//
//  =============================================================================
//  CHANGELOG (v3.0.0) — State-Driven Focus Recovery Architecture
//  =============================================================================
//
//  MAJOR VERSION BUMP: Architecture upgraded from "event-driven recovery" to
//  "state-driven + foreground-state protection + Quick Look black-hole shield".
//
//  This version consolidates all fixes from v2.1.3 through v2.1.5 into a stable
//  production-ready architecture.
//
//  -------------------------------------------------------------------------
//  ARCHITECTURE OVERVIEW
//  -------------------------------------------------------------------------
//
//  doFocusCheck() now runs a four-layer guard system (in order):
//
//    Guard 1 (Quick Look): isFinderQuickLookActive()
//      — Pure CGWindowList detection. Zero AX dependency.
//      — Blocks ALL recovery when Finder + floating panel coexist.
//
//    Guard 2 (Frontmost App Windows): frontmostAppHasVisibleWindow()
//      — Checks if frontmost app has ANY visible AXWindow (any subrole).
//      — Covers app startup Open Panel / Save Panel / Dialog states where
//        AXFocusedWindow may transiently be nil.
//
//    Guard 3 (Focused Window Validity): getCurrentFocusedWindow() +
//      isUsableFocusedWindow()
//      — Permissive validation: role==AXWindow, PID valid, not minimized.
//      — Accepts panels, dialogs, floating windows, sheets.
//
//    Recovery: findTopmostValidWindow() + isValidRecoveryTarget()
//      — Strict validation: only AXStandardWindow with close button.
//      — CGWindowList Z-order + bounds/title matching to AXWindow.
//
//  -------------------------------------------------------------------------
//  FIX #1 (from v2.1.3): Dual Validation Model
//  -------------------------------------------------------------------------
//  Split the single isValidStandardWindow() into two concepts:
//    — isUsableFocusedWindow(): permissive, for "does system have focus?"
//    — isValidRecoveryTarget(): strict, for "which window can RECEIVE focus?"
//
//  -------------------------------------------------------------------------
//  FIX #2 (from v2.1.3): Z-order Matching
//  -------------------------------------------------------------------------
//  Deleted getFirstAXWindow() (AXWindows.first). Replaced with matchAXWindow()
//  that maps CGWindowList entries to AXWindows via bounds+title matching.
//
//  -------------------------------------------------------------------------
//  FIX #3 (from v2.1.4): Finder Quick Look Hard Block
//  -------------------------------------------------------------------------
//  Added isFinderQuickLookActive() using CGWindowList + frontmost app.
//  Dual interception: scheduleFocusCheck() pre-filter + doFocusCheck() hard block.
//
//  -------------------------------------------------------------------------
//  FIX #4 (from v2.1.5): App Startup Open Panel Guard
//  -------------------------------------------------------------------------
//  Added frontmostAppHasVisibleWindow() as Guard 2.
//  Covers Keynote, Pixelmator Pro, etc. startup file selection dialogs.
//
//  -------------------------------------------------------------------------
//  SCENARIOS HANDLED CORRECTLY
//  -------------------------------------------------------------------------
//  - Finder Quick Look (Space preview)        -> 0 interference
//  - App startup Open / Save Panel            -> 0 interference
//  - Save / Open panels (any app)             -> no focus theft
//  - Spotlight                                -> no focus theft
//  - Xcode popups / code completion           -> no focus theft
//  - Chrome permission dialogs                -> no focus theft
//  - NSPanel / floating utility windows       -> no focus theft
//  - Multi-window Chrome/Xcode/Terminal       -> correct Z-order focus
//
//  =============================================================================

import AppKit
import ApplicationServices
import CoreGraphics
import Darwin

private typealias SpaceCopyCurrentFunc = @convention(c) (Int) -> Int
private typealias CopySpacesForWindowFunc = @convention(c) (Int, Int) -> Unmanaged<CFArray>?

final class WindowManager {

    private let accessibilityHelper: AccessibilityHelper
    private var observers: [pid_t: AXObserver] = [:]
    private var isMonitoring = false
    private var pendingFocusCheck = false
    private let settleDelay: TimeInterval = 0.05

    init(accessibilityHelper: AccessibilityHelper) {
        self.accessibilityHelper = accessibilityHelper
    }

    func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true

        print("[FocusTrafficLight] Starting")

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(applicationDidTerminate(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )

        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            observeApp(app)
        }

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(applicationDidLaunch(_:)),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
    }

    func stopMonitoring() {
        guard isMonitoring else { return }
        isMonitoring = false
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        for (_, observer) in observers {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        observers.removeAll()
    }

    @objc private func applicationDidLaunch(_ notification: Notification) {
        guard isEnabled(),
              let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        observeApp(app)
    }

    @objc private func applicationDidTerminate(_ notification: Notification) {
        guard isEnabled() else { return }
        scheduleFocusCheck()
    }

    private func observeApp(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard observers[pid] == nil else { return }

        var observer: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon = refcon else { return }
            let manager = Unmanaged<WindowManager>.fromOpaque(refcon).takeUnretainedValue()
            let name = notification as String
            if name == kAXUIElementDestroyedNotification as String ||
               name == kAXWindowMiniaturizedNotification as String {
                manager.scheduleFocusCheck()
            }
        }

        guard AXObserverCreate(pid, callback, &observer) == .success, let observer = observer else { return }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let appElement = AXUIElementCreateApplication(pid)
        AXObserverAddNotification(observer, appElement, kAXUIElementDestroyedNotification as CFString, selfPtr)
        AXObserverAddNotification(observer, appElement, kAXWindowMiniaturizedNotification as CFString, selfPtr)

        CFRunLoopAddSource(CFRunLoopGetCurrent(), AXObserverGetRunLoopSource(observer), .defaultMode)
        observers[pid] = observer
    }

    private func scheduleFocusCheck() {
        guard !pendingFocusCheck else { return }

        // Finder 空格预览期间不调度恢复检查
        if isFinderQuickLookActive() {
            return
        }

        pendingFocusCheck = true

        DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay) { [weak self] in
            self?.pendingFocusCheck = false
            self?.doFocusCheck()
        }
    }

    // MARK: - Focus Check Orchestration

    /// Core logic: only perform focus recovery when the system currently has NO usable focused window.
    private func doFocusCheck() {
        guard isEnabled(), accessibilityHelper.checkAccessibilityPermission() else { return }

        // Finder 按空格预览期间：完全禁止焦点恢复，交给系统自己处理
        if isFinderQuickLookActive() {
            print("[FocusTrafficLight] Finder Quick Look active, skipping recovery")
            return
        }

        print("[FocusTrafficLight] Focus check triggered")

        // Step 1: Check if frontmost app has any visible interactive window.
        // This covers app startup Open Panel / Save Panel / Dialog scenarios where
        // the focused window may transiently be nil, but the user is actively
        // interacting with a non-standard window (panel, dialog, sheet).
        if let frontmostApp = NSWorkspace.shared.frontmostApplication {
            if frontmostAppHasVisibleWindow(frontmostApp) {
                print("[FocusTrafficLight] Frontmost app has visible window, skipping recovery")
                return
            }
        }

        // Step 2: Check if system already has a usable focused window
        if let focusedWindow = getCurrentFocusedWindow() {
            if isUsableFocusedWindow(focusedWindow) {
                print("[FocusTrafficLight] System has usable focused window, skipping recovery")
                return
            }
        }

        // Step 3: Only recover when system is truly unfocused
        if let (window, app) = findTopmostValidWindow() {
            print("[FocusTrafficLight] Focusing: \(app.localizedName ?? "?")")
            performFocus(window: window, app: app)
        } else {
            print("[FocusTrafficLight] No valid window found")
        }
    }

    // MARK: - Current Focus Validation (Permissive)

    /// Gets the system-wide currently focused window via Accessibility API.
    private func getCurrentFocusedWindow() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedWindow: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(systemWide, kAXFocusedWindowAttribute as CFString, &focusedWindow)

        guard result == .success, let windowRef = focusedWindow else { return nil }
        return unsafeBitCast(windowRef, to: AXUIElement.self)
    }

    /// PERMISSIVE: Determines if the given window represents a "usable" system focus.
    ///
    /// This is intentionally lenient to avoid stealing focus from:
    /// - Quick Look panels (AXFloatingWindow / AXSystemDialog)
    /// - Save/Open panels (AXDialog / AXSheet)
    /// - Spotlight (AXSystemDialog)
    /// - Floating utility windows
    /// - Permission dialogs
    ///
    /// Rule: role must be AXWindow, PID must be valid, and window must not be minimized.
    /// Subrole is NOT strictly checked -- unknown subroles are accepted with a log warning.
    private func isUsableFocusedWindow(_ window: AXUIElement) -> Bool {
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &role)
        let roleStr = role as? String

        // Must be AXWindow role
        guard roleStr == kAXWindowRole as String else {
            return false
        }

        var subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subrole)
        let subroleStr = subrole as? String ?? ""

        var title: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
        let titleStr = (title as? String ?? "").prefix(30)

        // Must not be minimized
        var minimized: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimized)
        if let isMin = minimized as? Bool, isMin {
            return false
        }

        // Must have valid PID
        var pid: pid_t = 0
        AXUIElementGetPid(window, &pid)
        guard pid != 0 else {
            return false
        }

        // Known usable subroles -- these cover standard windows, dialogs, panels, sheets, etc.
        let knownUsableSubroles: [String] = [
            kAXStandardWindowSubrole as String,
            "AXDialog",
            "AXFloatingWindow",
            "AXSystemDialog",
            "AXSheet",
        ]

        if !knownUsableSubroles.contains(subroleStr) {
            // Accept unknown subroles defensively; log for awareness
            print("[FocusTrafficLight] Focused window has unknown subrole='\(subroleStr)' title='\(titleStr)', treating as usable")
        }

        return true
    }

    /// Checks whether the given app has any visible AXWindow (including panels,
    /// dialogs, sheets). Used to detect app startup Open Panel / Save Panel states
    /// where getCurrentFocusedWindow() may transiently return nil.
    private func frontmostAppHasVisibleWindow(_ app: NSRunningApplication) -> Bool {
        let pid = app.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)

        var windows: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windows)

        guard result == .success, let windowList = windows as? [AXUIElement] else {
            return false
        }

        for window in windowList {
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &role)
            let roleStr = role as? String

            guard roleStr == kAXWindowRole as String else { continue }

            var minimized: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimized)
            if let isMin = minimized as? Bool, isMin {
                continue
            }

            return true
        }

        return false
    }

    // MARK: - Recovery Target Discovery (Z-order Aware)

    /// Finds the topmost valid standard window using CGWindowList Z-order,
    /// then maps each CGWindow to its corresponding AXWindow via bounds+title matching.
    private func findTopmostValidWindow() -> (AXUIElement, NSRunningApplication)? {
        guard let cgWindowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            print("[FocusTrafficLight] No CGWindowList")
            return nil
        }

        let myPID = ProcessInfo.processInfo.processIdentifier

        for cgWindow in cgWindowList {
            // Only normal-layer windows (excludes menus, docks, etc.)
            guard let layer = cgWindow[kCGWindowLayer as String] as? Int, layer == 0 else { continue }

            // Only windows in current space
            guard windowIsInCurrentSpace(windowInfo: cgWindow) else { continue }

            // Get owner PID
            guard let ownerPID = cgWindow[kCGWindowOwnerPID as String] as? pid_t else { continue }
            if ownerPID == myPID { continue }

            // Get running application
            guard let app = NSRunningApplication(processIdentifier: ownerPID) else { continue }

            // Map CGWindow to AXWindow using bounds/title matching
            if let axWindow = matchAXWindow(for: cgWindow, app: app) {
                if isValidRecoveryTarget(axWindow) {
                    return (axWindow, app)
                }
            } else {
                // Fallback: some apps (e.g., Finder in certain states) expose CGWindow
                // but not a mappable AXWindow. Activate app directly in this case.
                if cgWindowBelongsToApp(windowInfo: cgWindow, app: app) {
                    print("[FocusTrafficLight] Found CGWindow but no mappable AXWindow for \(app.localizedName ?? "?"), will activate app directly")
                    return (AXUIElementCreateSystemWide(), app)
                }
            }
        }

        return nil
    }

    /// Maps a single CGWindow entry to the corresponding AXWindow by comparing
    /// bounds (position + size) and optionally title.
    ///
    /// This is the key to fixing multi-window app focus: instead of using AXWindows.first,
    /// we match against the real Z-order provided by CGWindowList.
    private func matchAXWindow(for cgWindow: [String: Any], app: NSRunningApplication) -> AXUIElement? {
        guard let cgBoundsDict = cgWindow[kCGWindowBounds as String] as? [String: CGFloat],
              let cgX = cgBoundsDict["X"],
              let cgY = cgBoundsDict["Y"],
              let cgWidth = cgBoundsDict["Width"],
              let cgHeight = cgBoundsDict["Height"] else {
            return nil
        }

        let cgBounds = CGRect(x: cgX, y: cgY, width: cgWidth, height: cgHeight)
        let cgName = cgWindow[kCGWindowName as String] as? String

        let axWindows = getAXWindows(for: app)

        for axWindow in axWindows {
            guard let axBounds = getAXWindowBounds(axWindow) else { continue }

            // Primary match: bounds (position + size) within 2pt tolerance
            let positionMatch = abs(axBounds.origin.x - cgBounds.origin.x) < 2 &&
                                abs(axBounds.origin.y - cgBounds.origin.y) < 2
            let sizeMatch = abs(axBounds.size.width - cgBounds.size.width) < 2 &&
                            abs(axBounds.size.height - cgBounds.size.height) < 2

            if positionMatch && sizeMatch {
                return axWindow
            }

            // Secondary match: exact title match + size match
            // (some windows may have slightly different positions due to AX vs CG coordinate differences)
            if let cgName = cgName, !cgName.isEmpty {
                var titleRef: CFTypeRef?
                AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef)
                if let axTitle = titleRef as? String, axTitle == cgName, sizeMatch {
                    return axWindow
                }
            }
        }

        return nil
    }

    /// Returns all AXWindows for a given application.
    private func getAXWindows(for app: NSRunningApplication) -> [AXUIElement] {
        let pid = app.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)

        var windows: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windows)

        guard result == .success, let windowList = windows as? [AXUIElement] else {
            return []
        }

        return windowList
    }

    /// Extracts the screen-space bounds (origin + size) from an AXWindow element.
    private func getAXWindowBounds(_ window: AXUIElement) -> CGRect? {
        var positionValue: CFTypeRef?
        var sizeValue: CFTypeRef?

        guard AXUIElementCopyAttributeValue(window, kAXPositionAttribute as CFString, &positionValue) == .success,
              AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success else {
            return nil
        }

        var position = CGPoint.zero
        var size = CGSize.zero

        AXValueGetValue(positionValue as! AXValue, .cgPoint, &position)
        AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)

        return CGRect(origin: position, size: size)
    }

    // MARK: - Recovery Target Validation (Strict)

    /// STRICT: Determines if a window is a valid target for focus recovery.
    ///
    /// Unlike isUsableFocusedWindow (which is permissive), this requires:
    /// - role == AXWindow
    /// - subrole == AXStandardWindow
    /// - Has close button (traffic lights)
    /// - Not minimized
    /// - Valid PID
    ///
    /// This ensures we only restore focus to "real" document windows, not panels or dialogs.
    private func isValidRecoveryTarget(_ window: AXUIElement) -> Bool {
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &role)
        let roleStr = role as? String ?? "?"

        var subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subrole)
        let subroleStr = subrole as? String ?? "?"

        var title: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
        let titleStr = (title as? String ?? "").prefix(20)

        // Must be AXWindow role
        if roleStr != kAXWindowRole as String {
            print("[FocusTrafficLight] Rejected recovery target: role='\(roleStr)' title='\(titleStr)'")
            return false
        }

        // Must be standard subrole
        if subroleStr != kAXStandardWindowSubrole as String {
            print("[FocusTrafficLight] Rejected recovery target: subrole='\(subroleStr)' title='\(titleStr)'")
            return false
        }

        // Must have close button (traffic lights)
        var closeButton: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &closeButton) == .success,
              closeButton != nil else {
            print("[FocusTrafficLight] Rejected recovery target: no close button title='\(titleStr)'")
            return false
        }

        // Must not be minimized
        var minimized: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimized)
        if let isMin = minimized as? Bool, isMin {
            print("[FocusTrafficLight] Rejected recovery target: minimized title='\(titleStr)'")
            return false
        }

        // Must have valid PID
        var pid: pid_t = 0
        AXUIElementGetPid(window, &pid)
        if pid == 0 {
            print("[FocusTrafficLight] Rejected recovery target: no PID title='\(titleStr)'")
            return false
        }

        return true
    }

    // MARK: - Focus Transfer

    private func performFocus(window: AXUIElement, app: NSRunningApplication) {
        app.activate(options: [.activateIgnoringOtherApps])

        var pid: pid_t = 0
        AXUIElementGetPid(window, &pid)

        if pid != 0 {
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, true as CFBoolean)
        }
    }

    // MARK: - Space / CGWindow Helpers

    private func getCurrentSpaceID() -> Int? {
        guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/Versions/Current/CoreGraphics", RTLD_NOW) else {
            return nil
        }
        defer { dlclose(handle) }

        guard let sym = dlsym(handle, "CGSSpaceCopyCurrent"),
              let fn = unsafeBitCast(sym, to: Optional<SpaceCopyCurrentFunc>.self) else {
            return nil
        }

        let currentSpace = fn(2) // kCGSSpaceUser
        if currentSpace != 0 {
            return currentSpace
        }
        return nil
    }

    private func windowIsInCurrentSpace(windowInfo: [String: Any]) -> Bool {
        guard let spaceID = getCurrentSpaceID() else {
            return true
        }

        guard let windowNumber = windowInfo[kCGWindowNumber as String] as? Int else {
            return false
        }

        guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/Versions/Current/CoreGraphics", RTLD_NOW) else {
            return true
        }
        defer { dlclose(handle) }

        guard let sym = dlsym(handle, "CGSCopySpacesForWindow"),
              let fn = unsafeBitCast(sym, to: Optional<CopySpacesForWindowFunc>.self) else {
            return true
        }

        guard let spacesRef = fn(2, windowNumber) else {
            return false
        }

        let spaces = spacesRef.takeRetainedValue() as! [Int]
        return spaces.contains(spaceID)
    }

    private func cgWindowBelongsToApp(windowInfo: [String: Any], app: NSRunningApplication) -> Bool {
        guard let ownerPID = windowInfo[kCGWindowOwnerPID as String] as? pid_t else { return false }
        return ownerPID == app.processIdentifier
    }

    // MARK: - Quick Look Detection (CGWindow-based, no AX)

    /// Detects whether Finder Quick Look (Space preview) is currently active.
    ///
    /// Uses only CGWindowList — does NOT rely on AX APIs (AXFocusedWindow,
    /// AXWindows, AX role/subrole). Detection rule:
    ///   frontmost app == Finder AND Finder has layer-0 window + non-layer-0 window.
    ///
    /// When active, all focus recovery is blocked. The system handles focus itself.
    private func isFinderQuickLookActive() -> Bool {
        guard let frontmostApp = NSWorkspace.shared.frontmostApplication,
              frontmostApp.bundleIdentifier == "com.apple.finder" else {
            return false
        }

        let finderPID = frontmostApp.processIdentifier

        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return false
        }

        var finderHasNormalWindow = false
        var finderHasFloatingPanel = false

        for windowInfo in windowList {
            guard let ownerPID = windowInfo[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID == finderPID else { continue }

            guard let layer = windowInfo[kCGWindowLayer as String] as? Int else { continue }

            if layer == 0 {
                finderHasNormalWindow = true
            } else {
                finderHasFloatingPanel = true
            }
        }

        return finderHasNormalWindow && finderHasFloatingPanel
    }

    private func isEnabled() -> Bool {
        return UserDefaults.standard.bool(forKey: "isEnabled")
    }
}
