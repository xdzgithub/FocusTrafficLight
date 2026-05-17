import AppKit
import ApplicationServices
import CoreGraphics

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
        pendingFocusCheck = true

        DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay) { [weak self] in
            self?.pendingFocusCheck = false
            self?.doFocusCheck()
        }
    }

    private func doFocusCheck() {
        guard isEnabled(), accessibilityHelper.checkAccessibilityPermission() else { return }

        print("[FocusTrafficLight] Focus check")

        // Step 1: Get current focused window and check if it's already valid
        if let currentWindow = getCurrentFocusedWindow(),
           isValidStandardWindow(currentWindow) {
            print("[FocusTrafficLight] Current window valid, done")
            return
        }

        // Step 2: Find topmost valid window using CGWindowList for Z-order
        if let (window, app) = findTopmostValidWindow() {
            print("[FocusTrafficLight] Focusing: \(app.localizedName ?? "?")")
            performFocus(window: window, app: app)
        } else {
            print("[FocusTrafficLight] No valid window found")
        }
    }

    private func getCurrentFocusedWindow() -> AXUIElement? {
        let systemWide = AXUIElementCreateSystemWide()
        var focusedWindow: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(systemWide, kAXFocusedWindowAttribute as CFString, &focusedWindow)

        guard result == .success, let windowRef = focusedWindow else { return nil }
        return unsafeBitCast(windowRef, to: AXUIElement.self)
    }

    // Step 1: Use CGWindowListCopyWindowInfo to get windows in Z-order
    private func findTopmostValidWindow() -> (AXUIElement, NSRunningApplication)? {
        // CGWindowListCopyWindowInfo returns windows in Z-order (front to back)
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            print("[FocusTrafficLight] No CGWindowList")
            return nil
        }

        let myPID = ProcessInfo.processInfo.processIdentifier

        for windowInfo in windowList {
            // Filter: only layer 0 (normal windows)
            guard let layer = windowInfo[kCGWindowLayer as String] as? Int, layer == 0 else { continue }

            // Get owner PID
            guard let ownerPID = windowInfo[kCGWindowOwnerPID as String] as? pid_t else { continue }

            // Skip this app
            if ownerPID == myPID { continue }

            // Get running app
            guard let app = NSRunningApplication(processIdentifier: ownerPID) else {
                print("[FocusTrafficLight] No running app for pid \(ownerPID)")
                continue
            }

            var appName = app.localizedName ?? "?"

            // Get AX window for this app
            if let axWindow = getFirstAXWindow(for: app) {
                if isValidStandardWindow(axWindow) {
                    return (axWindow, app)
                }
            } else {
                // Fallback: apps like Finder don't expose AX windows
                // Check if CGWindowList shows a window exists
                if cgWindowExistsForApp(windowInfo: windowInfo, app: app) {
                    print("[FocusTrafficLight] Found CGWindow but no AX window for \(appName), will activate app directly")
                    // Return the system-wide element to just activate the app
                    return (AXUIElementCreateSystemWide(), app)
                }
            }
        }

        return nil
    }

    private func cgWindowExistsForApp(windowInfo: [String: Any], app: NSRunningApplication) -> Bool {
        // Check if CGWindowList shows a window for this app
        guard let ownerPID = windowInfo[kCGWindowOwnerPID as String] as? pid_t else { return false }
        return ownerPID == app.processIdentifier
    }

    private func getFirstAXWindow(for app: NSRunningApplication) -> AXUIElement? {
        let pid = app.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)

        var windows: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windows)

        if result != .success {
            print("[FocusTrafficLight] AXWindows failed for \(app.localizedName ?? "?")")
            return nil
        }

        guard let windowList = windows as? [AXUIElement], let firstWindow = windowList.first else {
            print("[FocusTrafficLight] Empty AXWindow list for \(app.localizedName ?? "?")")
            return nil
        }

        return firstWindow
    }

    // Step 2: Deep audit using Accessibility API
    private func isValidStandardWindow(_ window: AXUIElement) -> Bool {
        var role: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXRoleAttribute as CFString, &role)
        let roleStr = role as? String ?? "?"

        var subrole: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXSubroleAttribute as CFString, &subrole)
        let subroleStr = subrole as? String ?? "?"

        var title: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &title)
        let titleStr = (title as? String ?? "?").prefix(20)

        // Check 1: Must be AXWindow role
        if roleStr != kAXWindowRole as String {
            print("[FocusTrafficLight] Rejected: role='\(roleStr)' title='\(titleStr)'")
            return false
        }

        // Check 2: Must be standard subrole
        if subroleStr != kAXStandardWindowSubrole as String {
            print("[FocusTrafficLight] Rejected: subrole='\(subroleStr)' title='\(titleStr)'")
            return false
        }

        // Check 3: Must have close button (traffic lights)
        var closeButton: CFTypeRef?
        guard AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &closeButton) == .success,
              closeButton != nil else {
            print("[FocusTrafficLight] Rejected: no close button title='\(titleStr)'")
            return false
        }

        // Check 4: Must not be minimized
        var minimized: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &minimized)
        if let isMin = minimized as? Bool, isMin {
            print("[FocusTrafficLight] Rejected: minimized title='\(titleStr)'")
            return false
        }

        // Check 5: Window must have valid PID
        var pid: pid_t = 0
        AXUIElementGetPid(window, &pid)
        if pid == 0 {
            print("[FocusTrafficLight] Rejected: no PID title='\(titleStr)'")
            return false
        }

        return true
    }

    // Step 4: Focus transfer
    private func performFocus(window: AXUIElement, app: NSRunningApplication) {
        // First: activate the app
        app.activate(options: [.activateIgnoringOtherApps])

        // If window is valid (not empty), perform window focus
        var pid: pid_t = 0
        AXUIElementGetPid(window, &pid)

        if pid != 0 {
            // Second: raise the window
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)

            // Third: set focused
            AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, true as CFBoolean)
        }
    }

    private func isEnabled() -> Bool {
        return UserDefaults.standard.bool(forKey: "isEnabled")
    }
}
