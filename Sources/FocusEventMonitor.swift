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
    private let launchGracePeriod: TimeInterval = 2.0
    private var launchTimestamps: [pid_t: TimeInterval] = [:]
    private let launchLock = NSLock()

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
        let pid = app.processIdentifier
        AppLogger.info("App launched: \(app.localizedName ?? "?") bundleID=\(app.bundleIdentifier ?? "?")")
        launchLock.lock()
        launchTimestamps[pid] = Date().timeIntervalSince1970
        launchLock.unlock()
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

                // Only respond to events from the frontmost application.
                // Background apps create/destroy internal UI elements
                // constantly (notifications, auto-save panels, helper
                // windows). Without this filter, an unrelated AX event
                // from a background app can trigger performRecoveryCheck()
                // during a user-initiated app switch, causing the recovery
                // engine to steal focus back to the previous app.
                let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
                if eventPID != frontmostPID {
                    AppLogger.info("Skip check — PID=\(eventPID) not frontmost (\(frontmostPID))")
                    return
                }

                // Cold-launch apps create/destroy internal UI elements during
                // window setup. If the app launched recently, skip the focus
                // check — its real window may not be in CGWindowList yet.
                if name == kAXUIElementDestroyedNotification as String {
                    monitor.launchLock.lock()
                    let launchTime = monitor.launchTimestamps[eventPID]
                    monitor.launchLock.unlock()
                    if let t = launchTime,
                       Date().timeIntervalSince1970 - t < monitor.launchGracePeriod {
                        AppLogger.info("Skip check — app launched \(String(format: "%.1f", Date().timeIntervalSince1970 - t))s ago (PID=\(eventPID))")
                        return
                    }
                }

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
