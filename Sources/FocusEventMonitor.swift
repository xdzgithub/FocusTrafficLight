import AppKit
import ApplicationServices

/// Manages AXObserver lifecycle for all running applications and schedules
/// deferred focus checks in response to window lifecycle events.
///
/// Design: This class is purely an "event source". It does NOT make any
/// focus recovery decisions. When an event occurs, it notifies the delegate
/// to perform a state-driven check.
final class FocusEventMonitor {

    private var observers: [pid_t: AXObserver] = [:]
    private var isMonitoring = false
    private var pendingFocusCheck = false
    private let settleDelay: TimeInterval = 0.05

    /// Called when a window event (close/minimize/hide) may require focus recovery.
    var onFocusCheckNeeded: (() -> Void)?

    /// Called when a new app launches while monitoring is active.
    var onAppLaunched: ((NSRunningApplication) -> Void)?

    func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true

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

    // MARK: - NSWorkspace Notifications

    @objc private func applicationDidLaunch(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        AppLogger.info("App launched: \(app.localizedName ?? "?") bundleID=\(app.bundleIdentifier ?? "?")")
        onAppLaunched?(app)
        observeApp(app)
    }

    // MARK: - AXObserver Setup

    private func observeApp(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard observers[pid] == nil else { return }

        var observer: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon = refcon else { return }
            let monitor = Unmanaged<FocusEventMonitor>.fromOpaque(refcon).takeUnretainedValue()
            let name = notification as String
            if name == kAXUIElementDestroyedNotification as String ||
               name == kAXWindowMiniaturizedNotification as String {
                var eventPID: pid_t = 0
                AXUIElementGetPid(element, &eventPID)
                AppLogger.info("AX event: \(name) on PID=\(eventPID)")
                monitor.scheduleFocusCheck()
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

    // MARK: - Deferred Focus Check Scheduling

    func scheduleFocusCheck() {
        guard !pendingFocusCheck else { return }
        pendingFocusCheck = true

        DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay) { [weak self] in
            self?.pendingFocusCheck = false
            self?.onFocusCheckNeeded?()
        }
    }
}
