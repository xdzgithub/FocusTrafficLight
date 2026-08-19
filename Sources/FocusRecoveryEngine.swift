import AppKit
import ApplicationServices
import CoreGraphics
import Darwin

private typealias SpaceCopyCurrentFunc = @convention(c) (Int) -> Int
private typealias CopySpacesForWindowFunc = @convention(c) (Int, Int) -> Unmanaged<CFArray>?

/// State-driven focus recovery engine. Makes recovery decisions based on
/// current system state, not individual events.
///
/// Four-layer guard system:
///   1. Finder Quick Look detection (CGWindow-based)
///   2. Frontmost app visible window check (covers Open Panel / Save Panel)
///   3. Current focused window validity check (AX-based, permissive)
///   4. Recovery target discovery (CGWindow Z-order + AXWindow matching, strict)
final class FocusRecoveryEngine {

    private let accessibilityHelper: AccessibilityHelper

    init(accessibilityHelper: AccessibilityHelper) {
        self.accessibilityHelper = accessibilityHelper
    }

    // MARK: - Recovery Orchestration

    /// Performs a full state-driven focus recovery check.
    /// Only recovers focus when ALL guards indicate the system has no valid foreground state.
    func performRecoveryCheck() {
        guard accessibilityHelper.checkAccessibilityPermission() else { return }

        let frontmostApp = NSWorkspace.shared.frontmostApplication
        AppLogger.info("Focus check triggered — frontmost: \(frontmostApp?.localizedName ?? "nil") bundleID=\(frontmostApp?.bundleIdentifier ?? "nil")")

        // Guard 1: Quick Look hard block. Space-bar previews are left entirely
        // to the system — while a preview is up, the engine must not act.
        if isFinderQuickLookActive() {
            AppLogger.info("Guard 1: Finder Quick Look active, skipping recovery")
            return
        }

        // Guard 2: Frontmost app has any visible interactive window
        if let frontmostApp = frontmostApp,
           frontmostAppHasVisibleWindow(frontmostApp) {
            AppLogger.info("Guard 2: Frontmost app has visible window, skipping recovery")
            return
        }

        // Guard 3: System already has a usable focused window
        if let focusedWindow = getCurrentFocusedWindow() {
            if isUsableFocusedWindow(focusedWindow) {
                AppLogger.info("Guard 3: Usable focused window exists, skipping recovery")
                return
            }
        }

        // Guard 4: Find and focus the topmost valid recovery target
        AppLogger.info("All guards cleared — performing focus recovery")
        if let (window, app) = findTopmostValidWindow() {
            AppLogger.info("Focusing: \(app.localizedName ?? "?")")
            performFocus(window: window, app: app)
        } else {
            AppLogger.info("No valid recovery target found")
        }
    }

    // MARK: - Guard 1: Quick Look Detection (CGWindow-based, no AX)

    /// Returns true while Finder Quick Look (space-bar preview) is active.
    /// Space-bar previews must be left entirely to the system.
    private func isFinderQuickLookActive() -> Bool {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return false
        }

        let frontmost = NSWorkspace.shared.frontmostApplication
        let finderPID = frontmost?.bundleIdentifier == "com.apple.finder" ? frontmost?.processIdentifier : nil
        var finderHasNormalWindow = false
        var finderHasFloatingPanel = false

        for windowInfo in windowList {
            guard let layer = windowInfo[kCGWindowLayer as String] as? Int else { continue }

            // The space-bar preview panel is served by the QuickLookUIService
            // helper process (macOS 14+), not Finder. Treat any Quick Look
            // floating window as the preview being active.
            if let ownerName = windowInfo[kCGWindowOwnerName as String] as? String,
               ownerName.lowercased().contains("quicklook"),
               layer > 0 {
                return true
            }

            // Legacy detection: Finder's own normal window + floating panel.
            if let finderPID = finderPID,
               let ownerPID = windowInfo[kCGWindowOwnerPID as String] as? pid_t,
               ownerPID == finderPID {
                if layer == 0 {
                    finderHasNormalWindow = true
                } else {
                    finderHasFloatingPanel = true
                }
            }
        }

        return finderHasNormalWindow && finderHasFloatingPanel
    }

    // MARK: - Guard 2: Frontmost App Visible Window

    /// Checks whether the given app has any visible AXWindow (including panels,
    /// dialogs, sheets). Cross-references with CGWindowList to exclude hidden
    /// background windows that AX still lists as visible.
    private func frontmostAppHasVisibleWindow(_ app: NSRunningApplication) -> Bool {
        let pid = app.processIdentifier

        // Get the set of window numbers that are actually on screen (CGWindow).
        guard let cgWindowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return false
        }

        var onScreenWindowNumbers = Set<Int>()
        for cgWindow in cgWindowList {
            guard let layer = cgWindow[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard let ownerPID = cgWindow[kCGWindowOwnerPID as String] as? pid_t, ownerPID == pid else { continue }
            guard let windowNumber = cgWindow[kCGWindowNumber as String] as? Int else { continue }
            onScreenWindowNumbers.insert(windowNumber)
        }

        guard !onScreenWindowNumbers.isEmpty else {
            return false
        }

        // Verify at least one on-screen window has a valid AXWindow counterpart.
        let appElement = AXUIElementCreateApplication(pid)
        var windows: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windows)

        guard result == .success, let windowList = windows as? [AXUIElement] else {
            return false
        }

        var candidateCount = 0
        for window in windowList {
            var role: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &role)
            guard (role as? String) == kAXWindowRole as String else { continue }

            var minimized: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimized)
            if let isMin = minimized as? Bool, isMin { continue }

            // Filter out invisible helper windows (<100×100px)
            var sizeValue: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, kAXSizeAttribute as CFString, &sizeValue) == .success {
                var size = CGSize.zero
                AXValueGetValue(sizeValue as! AXValue, .cgSize, &size)
                if size.width < 100 || size.height < 100 { continue }
            }

            candidateCount += 1

            // Confirm this AX window is actually on screen (cross-reference CGWindow)
            var windowNumber: CFTypeRef?
            if AXUIElementCopyAttributeValue(window, "AXCGWindowID" as CFString, &windowNumber) == .success,
               let cgID = windowNumber as? Int,
               onScreenWindowNumbers.contains(cgID) {
                return true
            }
        }

        // CGWindowID cross-reference didn't match, but CG has windows on screen
        // AND AX sees valid window candidates — treat as visible (happens with
        // window tiling, split-screen, and some apps like eM Client).
        if candidateCount > 0 {
            return true
        }

        return false
    }

    // MARK: - Guard 3: Current Focus Validation (Permissive)

    private func getCurrentFocusedWindow() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedWindow: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(systemWide, kAXFocusedWindowAttribute as CFString, &focusedWindow)

        guard result == .success, let windowRef = focusedWindow else { return nil }
        return (windowRef as! AXUIElement)
    }

    private func isUsableFocusedWindow(_ window: AXUIElement) -> Bool {
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &role)
        let roleStr = role as? String

        guard roleStr == kAXWindowRole as String else {
            return false
        }

        var subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subrole)
        let subroleStr = subrole as? String ?? ""

        var title: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
        let titleStr = (title as? String ?? "").prefix(30)

        var minimized: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimized)
        if let isMin = minimized as? Bool, isMin {
            return false
        }

        var pid: pid_t = 0
        AXUIElementGetPid(window, &pid)
        guard pid != 0 else {
            return false
        }

        let knownUsableSubroles: [String] = [
            kAXStandardWindowSubrole as String,
            "AXDialog",
            "AXFloatingWindow",
            "AXSystemDialog",
            "AXSheet",
        ]

        if !knownUsableSubroles.contains(subroleStr) {
            AppLogger.debug("Focused window has unknown subrole='\(subroleStr)' title='\(titleStr)', treating as usable")
        }

        return true
    }

    // MARK: - Guard 4: Recovery Target Discovery (Z-order Aware)

    private func findTopmostValidWindow() -> (AXUIElement, NSRunningApplication)? {
        guard let cgWindowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            AppLogger.debug("No CGWindowList")
            return nil
        }

        let myPID = ProcessInfo.processInfo.processIdentifier

        for cgWindow in cgWindowList {
            guard let layer = cgWindow[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard windowIsInCurrentSpace(windowInfo: cgWindow) else { continue }
            guard let ownerPID = cgWindow[kCGWindowOwnerPID as String] as? pid_t else { continue }
            if ownerPID == myPID { continue }
            guard let app = NSRunningApplication(processIdentifier: ownerPID) else { continue }

            if let axWindow = matchAXWindow(for: cgWindow, app: app) {
                if isValidRecoveryTarget(axWindow) {
                    return (axWindow, app)
                }
            } else {
                if cgWindowBelongsToApp(windowInfo: cgWindow, app: app) {
                    AppLogger.debug("Found CGWindow but no mappable AXWindow for \(app.localizedName ?? "?"), will activate app directly")
                    return (AXUIElementCreateSystemWide(), app)
                }
            }
        }

        return nil
    }

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

            let positionMatch = abs(axBounds.origin.x - cgBounds.origin.x) < 2 &&
                                abs(axBounds.origin.y - cgBounds.origin.y) < 2
            let sizeMatch = abs(axBounds.size.width - cgBounds.size.width) < 2 &&
                            abs(axBounds.size.height - cgBounds.size.height) < 2

            if positionMatch && sizeMatch {
                return axWindow
            }

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

        if roleStr != kAXWindowRole as String {
            AppLogger.debug("Rejected recovery target: role=\(roleStr) title=\(titleStr)")
            return false
        }

        if subroleStr != kAXStandardWindowSubrole as String &&
           subroleStr != "AXDialog" &&
           subroleStr != "AXFloatingWindow" &&
           subroleStr != "AXSystemDialog" {
            AppLogger.debug("Rejected recovery target: subrole=\(subroleStr) title=\(titleStr)")
            return false
        }

        var closeButton: CFTypeRef?
        let hasCloseButton = AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &closeButton) == .success && closeButton != nil
        if !hasCloseButton {
            AppLogger.debug("Recovery target has no close button title=\(titleStr), accepting anyway")
        }

        var minimized: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimized)
        if let isMin = minimized as? Bool, isMin {
            AppLogger.debug("Rejected recovery target: minimized title=\(titleStr)")
            return false
        }

        var pid: pid_t = 0
        AXUIElementGetPid(window, &pid)
        if pid == 0 {
            AppLogger.debug("Rejected recovery target: no PID title=\(titleStr)")
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

        let currentSpace = fn(2)
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
}
