import AppKit
import ApplicationServices
import CoreGraphics

final class WindowManager {

    private let accessibilityHelper: AccessibilityHelper
    private var observers: [pid_t: AXObserver] = [:]
    private var isMonitoring = false
    private var pendingFocusCheck = false
    private let settleDelay: TimeInterval = 0.5

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

        print("[FocusTrafficLight] === Focus check ===")

        let systemWide = AXUIElementCreateSystemWide()
        var focusedWindow: CFTypeRef?
        let windowResult = AXUIElementCopyAttributeValue(systemWide, kAXFocusedWindowAttribute as CFString, &focusedWindow)

        if windowResult == .success, let windowRef = focusedWindow {
            let window = unsafeBitCast(windowRef, to: AXUIElement.self)
            if hasTrafficLights(window) {
                print("[FocusTrafficLight] Already valid, done")
                return
            }
        }

        print("[FocusTrafficLight] Finding window...")

        if let (window, app) = findTopmostWindow() {
            print("[FocusTrafficLight] Focusing: \(app.localizedName ?? "?")")
            doFocus(window: window, app: app)
        } else {
            print("[FocusTrafficLight] No valid window")
        }
    }

    private func findTopmostWindow() -> (AXUIElement, NSRunningApplication)? {
        let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []

        for windowInfo in windowList {
            guard let ownerPID = windowInfo[kCGWindowOwnerPID as String] as? pid_t,
                  let layer = windowInfo[kCGWindowLayer as String] as? Int,
                  layer == 0 else { continue }

            guard let app = NSRunningApplication(processIdentifier: ownerPID),
                  app.activationPolicy == .regular else { continue }

            if let axWindow = findAXWindow(for: app) {
                if hasTrafficLights(axWindow) && !isMinimized(axWindow) {
                    var title: CFTypeRef?
                    AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &title)
                    let titleStr = (title as? String ?? "?").prefix(30)
                    print("[FocusTrafficLight] Found: \(app.localizedName ?? "?") - '\(titleStr)'")
                    return (axWindow, app)
                }
            }
        }

        return nil
    }

    private func findAXWindow(for app: NSRunningApplication) -> AXUIElement? {
        let pid = app.processIdentifier
        let appElement = AXUIElementCreateApplication(pid)

        var windows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windows) == .success,
              let windowList = windows as? [AXUIElement] else { return nil }

        return windowList.first
    }

    private func hasTrafficLights(_ window: AXUIElement) -> Bool {
        var closeButton: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(window, kAXCloseButtonAttribute as CFString, &closeButton)
        return result == .success && closeButton != nil
    }

    private func isMinimized(_ window: AXUIElement) -> Bool {
        var min: CFTypeRef?
        AXUIElementCopyAttributeValue(window, kAXMinimizedAttribute as CFString, &min)
        return min as? Bool ?? false
    }

    private func doFocus(window: AXUIElement, app: NSRunningApplication) {
        AXUIElementPerformAction(window, kAXRaiseAction as CFString)
        app.activate(options: [.activateIgnoringOtherApps])
        AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, true as CFBoolean)
    }

    private func isEnabled() -> Bool {
        return UserDefaults.standard.bool(forKey: "isEnabled")
    }
}
