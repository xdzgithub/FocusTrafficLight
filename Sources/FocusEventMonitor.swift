import AppKit
import ApplicationServices
import CoreGraphics

/// A single user-initiated window close/minimize action.
struct FocusTriggerContext {
    enum Kind: String {
        case closeWindow = "Cmd+W"
        case minimizeWindow = "Cmd+M"
        case closeButton = "Close Button"
        case minimizeButton = "Minimize Button"
        case windowHidden = "Window Hidden"
    }

    let kind: Kind
    let sourcePID: pid_t
    let targetWindowID: Int?
}

/// V5 event source: keyboard shortcuts, traffic light clicks, and app-hide
/// notifications from apps with their own hide shortcuts (WeChat, QQ, Feishu...).
///
/// Explicit user actions can schedule focus recovery:
///   - Cmd+W closes a window
///   - Cmd+M minimizes a window
///   - a real mouse click on the red close / yellow minimize button
///   - a frontmost app hides itself or removes all of its traffic-light
///     windows through an app-specific shortcut
///
/// macOS 27 notes: the private `AXCGWindowID` attribute no longer exists, so an
/// accessibility element can no longer be mapped back to its `CGWindowID`. The
/// target window is now identified through `WindowOrderService` instead, and the
/// Finder desktop / Quick Look filter uses geometry rather than window titles
/// (titles require Screen Recording and read as empty without it).
final class FocusEventMonitor {

    /// System helper apps that open a transient progress window and quit.
    /// Their window destruction is not a user hide action and must be left to
    /// macOS, otherwise recovery can pull focus back to the previous app.
    private static let transientSystemBundleIdentifiers: Set<String> = [
        "com.apple.archiveutility",
        "com.apple.DiskImageMounter"
    ]

    private struct TrafficLightHit {
        let kind: FocusTriggerContext.Kind
        let pid: pid_t
        let windowID: Int?
    }

    private var globalEventMonitor: Any?
    private var mouseEventTap: CFMachPort?
    private var mouseTapRunLoop: CFRunLoop?
    private var mouseTapContext: UnsafeMutableRawPointer?
    private var mouseTapThread: Thread?
    private var isMonitoring = false

    private var observers: [pid_t: (observer: AXObserver, runLoopSource: CFRunLoopSource, retainedSelf: UnsafeMutableRawPointer)] = [:]
    private var lastCmdHAt: TimeInterval = 0

    /// The recovery check starts immediately; it polls, so a small delay here
    /// would only be added to every trigger's latency.
    private let settleDelay: TimeInterval = 0
    private let debounceInterval: TimeInterval = 0.2
    private var lastTriggerAt: TimeInterval = 0

    private let windowOrder = WindowOrderService()

    /// Called shortly after the user closes/minimizes a window.
    var onFocusCheckNeeded: ((FocusTriggerContext) -> Void)?

    func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true

        globalEventMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            self?.handleKeyDown(event)
        }

        startMouseEventTap()
        observeRunningApplications()

        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(applicationDidLaunch(_:)),
            name: NSWorkspace.didLaunchApplicationNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(applicationDidTerminate(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )

        AppLogger.notice("Focus event sources started (Cmd+W / Cmd+M / traffic lights / app hide)")
    }

    func stopMonitoring() {
        guard isMonitoring else { return }
        isMonitoring = false

        NSWorkspace.shared.notificationCenter.removeObserver(self)
        removeAllObservers()
        stopMouseEventTap()

        if let monitor = globalEventMonitor {
            NSEvent.removeMonitor(monitor)
            globalEventMonitor = nil
        }
    }

    // MARK: - Keyboard Events

    private func handleKeyDown(_ event: NSEvent) {
        guard event.modifierFlags.contains(.command), !event.isARepeat else { return }

        if event.keyCode == 4 {
            lastCmdHAt = Date().timeIntervalSince1970
        }

        let kind: FocusTriggerContext.Kind
        switch event.keyCode {
        case 13: kind = .closeWindow
        case 46: kind = .minimizeWindow
        default: return
        }

        guard canTriggerNow() else { return }

        let pid = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
        let snapshot = windowOrder.takeSnapshot()
        // The key event's window number is the window being closed/minimized.
        // Synthetic and replayed events can carry a stale or foreign number, so
        // only trust it when it really belongs to the frontmost app; otherwise
        // fall back to that app's frontmost window.
        let windowID: Int?
        if event.windowNumber != 0, snapshot.ownerPID(ofWindowID: event.windowNumber) == pid {
            windowID = event.windowNumber
        } else {
            windowID = snapshot.topmostWindow(ownerPID: pid)?.windowID
        }

        schedule(
            FocusTriggerContext(
                kind: kind,
                sourcePID: pid,
                targetWindowID: windowID
            )
        )
    }

    // MARK: - Mouse Events (Traffic Light Clicks)

    private func startMouseEventTap() {
        guard mouseEventTap == nil else { return }

        AppLogger.notice(
            "Mouse tap setup: AX trusted=\(AXIsProcessTrusted()) tapExists=\(mouseEventTap != nil)"
        )

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard type == .leftMouseDown,
                  let refcon = refcon else {
                return Unmanaged.passUnretained(event)
            }

            let monitor = Unmanaged<FocusEventMonitor>.fromOpaque(refcon).takeUnretainedValue()
            monitor.handleMouseDown(at: event.location)
            return Unmanaged.passUnretained(event)
        }

        let selfPtr = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cghidEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: CGEventMask(1 << CGEventType.leftMouseDown.rawValue),
            callback: callback,
            userInfo: selfPtr
        ) else {
            AppLogger.notice("Traffic light mouse tap unavailable (Accessibility or Input Monitoring permission needed)")
            return
        }
        AppLogger.notice("Traffic light mouse tap created")

        let tapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        mouseEventTap = tap
        mouseTapContext = selfPtr

        mouseTapThread = Thread { [weak self] in
            let runLoop = CFRunLoopGetCurrent()
            self?.mouseTapRunLoop = runLoop
            CFRunLoopAddSource(runLoop, tapSource, .defaultMode)
            CFRunLoopRun()
            CFRunLoopRemoveSource(runLoop, tapSource, .defaultMode)
            self?.mouseTapRunLoop = nil
        }
        mouseTapThread?.name = "FocusTrafficLight.MouseTap"
        mouseTapThread?.start()
        AppLogger.debug("Traffic light mouse tap thread starting")
    }

    private func stopMouseEventTap() {
        if let tap = mouseEventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
            mouseEventTap = nil
        }
        if let runLoop = mouseTapRunLoop {
            CFRunLoopStop(runLoop)
        }
        if let context = mouseTapContext {
            _ = Unmanaged<FocusEventMonitor>.fromOpaque(context)
            mouseTapContext = nil
        }
    }

    private func handleMouseDown(at point: CGPoint) {
        DispatchQueue.main.async { [weak self] in
            self?.handleMouseDownOnMain(at: point)
        }
    }

    private func handleMouseDownOnMain(at point: CGPoint) {
        guard let hit = trafficLightHit(at: point) else {
            AppLogger.debug("Mouse down at \(Int(point.x)),\(Int(point.y)) did not hit a traffic light")
            return
        }
        guard canTriggerNow() else { return }

        AppLogger.notice(
            "Traffic light clicked: \(hit.kind.rawValue) PID=\(hit.pid) (\(NSRunningApplication(processIdentifier: hit.pid)?.localizedName ?? "?"))"
        )

        schedule(
            FocusTriggerContext(
                kind: hit.kind,
                sourcePID: hit.pid,
                targetWindowID: hit.windowID
            )
        )
    }

    /// Returns the close/minimize button under the click point, if any.
    ///
    /// AX exposes traffic lights as `AXCloseButton` / `AXMinimizeButton`
    /// children of the window. Some apps wrap them one level deep, so walk up
    /// a few parents before giving up. This never falls back to generic
    /// `AXButton` hits, keeping clicks inside web content and custom UI inert.
    private func trafficLightHit(at point: CGPoint) -> TrafficLightHit? {
        let systemWide = AXUIElementCreateSystemWide()
        var hit: AXUIElement?
        guard AXUIElementCopyElementAtPosition(systemWide, Float(point.x), Float(point.y), &hit) == .success,
              let hitElement = hit else {
            return nil
        }

        var element = hitElement
        for _ in 0..<4 {
            if let kind = trafficLightKind(of: element) {
                var pid: pid_t = 0
                guard AXUIElementGetPid(element, &pid) == .success,
                      pid != 0,
                      pid != ProcessInfo.processInfo.processIdentifier else {
                    return nil
                }
                return TrafficLightHit(
                    kind: kind,
                    pid: pid,
                    windowID: enclosingWindowID(of: element)
                )
            }

            guard let parent = AXGeometry.parent(of: element) else { break }
            element = parent
        }

        return nil
    }

    /// Walks up from a traffic light button to its window and resolves that
    /// window's `CGWindowID` by frame.
    private func enclosingWindowID(of element: AXUIElement) -> Int? {
        var current: AXUIElement? = element
        for _ in 0..<8 {
            guard let candidate = current else { return nil }
            if (AXGeometry.attribute(of: candidate, key: kAXRoleAttribute as CFString) as? String) == kAXWindowRole as String {
                return windowID(of: candidate)
            }
            current = AXGeometry.parent(of: candidate)
        }
        return nil
    }

    private func trafficLightKind(of element: AXUIElement) -> FocusTriggerContext.Kind? {
        let subrole = AXGeometry.attribute(of: element, key: kAXSubroleAttribute as CFString) as? String
        let role = AXGeometry.attribute(of: element, key: kAXRoleAttribute as CFString) as? String

        if subrole == kAXCloseButtonSubrole as String || role == kAXCloseButtonAttribute as String {
            return .closeButton
        }
        if subrole == kAXMinimizeButtonSubrole as String || role == kAXMinimizeButtonAttribute as String {
            return .minimizeButton
        }
        return nil
    }

    private func windowID(of element: AXUIElement) -> Int? {
        guard let frame = AXGeometry.frame(of: element) else { return nil }
        return windowOrder.takeSnapshot().windowID(matchingFrame: frame)
    }

    /// Returns true when a Finder destroy/minimize notification should be
    /// suppressed as desktop / Quick Look noise.
    ///
    /// A destroyed element cannot be inspected — reading its subrole or frame
    /// fails — so the destroyed element itself is useless as evidence. The app
    /// element is still readable, and Finder reports the desktop as a window in
    /// that list, so the discriminator is whether any *standard* Finder window
    /// exists. If none does, only the desktop was involved and nothing real was
    /// closed.
    ///
    /// Genuine Finder close/minimize is still recovered through the Cmd+W /
    /// Cmd+M and traffic-light-click triggers, which do not depend on this path.
    private func isFinderDesktopNoise(pid: pid_t) -> Bool {
        guard let appElement = AXUIElementCreateApplication(pid) as AXUIElement?,
              let windows = AXGeometry.attribute(of: appElement, key: kAXWindowsAttribute as CFString) as? [AXUIElement] else {
            return true
        }
        let hasStandardWindow = windows.contains {
            (AXGeometry.attribute(of: $0, key: kAXSubroleAttribute as CFString) as? String) == kAXStandardWindowSubrole as String
        }
        if !hasStandardWindow {
            AppLogger.notice("Skip Finder AX event — no standard Finder window (desktop/Quick Look noise)")
        }
        return !hasStandardWindow
    }

    private func canTriggerNow() -> Bool {
        let now = Date().timeIntervalSince1970
        guard now - lastTriggerAt >= debounceInterval else { return false }
        lastTriggerAt = now
        return true
    }

    private func schedule(_ context: FocusTriggerContext) {
        AppLogger.notice(
            "Focus trigger queued: \(context.kind.rawValue) PID=\(context.sourcePID) window=\(context.targetWindowID.map(String.init) ?? "?")"
        )

        DispatchQueue.main.asyncAfter(deadline: .now() + settleDelay) { [weak self] in
            self?.onFocusCheckNeeded?(context)
        }
    }

    // MARK: - App Hide Notifications (WeChat / QQ / Feishu style shortcuts)

    private func observeRunningApplications() {
        for app in NSWorkspace.shared.runningApplications where app.activationPolicy == .regular {
            observeApp(app)
        }
    }

    @objc private func applicationDidLaunch(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
              app.activationPolicy == .regular else {
            return
        }
        observeApp(app)
    }

    @objc private func applicationDidTerminate(_ notification: Notification) {
        guard let app = notification.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else {
            return
        }
        removeObserver(for: app.processIdentifier)
    }

    private func observeApp(_ app: NSRunningApplication) {
        let pid = app.processIdentifier
        guard observers[pid] == nil else { return }
        guard !Self.transientSystemBundleIdentifiers.contains(app.bundleIdentifier ?? "") else {
            return
        }

        var observer: AXObserver?
        let callback: AXObserverCallback = { _, element, notification, refcon in
            guard let refcon = refcon else { return }
            let monitor = Unmanaged<FocusEventMonitor>.fromOpaque(refcon).takeUnretainedValue()
            monitor.handleAXNotification(element: element, name: notification as String)
        }

        guard AXObserverCreate(pid, callback, &observer) == .success,
              let observer = observer else {
            AppLogger.notice("AXObserver unavailable for PID=\(pid) (\(app.localizedName ?? "?"))")
            return
        }

        let retainedSelf = Unmanaged.passRetained(self).toOpaque()
        let appElement = AXUIElementCreateApplication(pid)

        let notifications: [CFString] = [
            kAXUIElementDestroyedNotification as CFString,
            kAXWindowMiniaturizedNotification as CFString,
            kAXApplicationHiddenNotification as CFString
        ]

        var registered = 0
        for name in notifications {
            if AXObserverAddNotification(observer, appElement, name, retainedSelf) == .success {
                registered += 1
            } else {
                AppLogger.notice("AXObserverAddNotification failed: \(name) PID=\(pid)")
            }
        }
        guard registered > 0 else {
            _ = Unmanaged<FocusEventMonitor>.fromOpaque(retainedSelf)
            AppLogger.notice("No AX notifications registered for PID=\(pid) (\(app.localizedName ?? "?"))")
            return
        }

        let runLoopSource = AXObserverGetRunLoopSource(observer)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), runLoopSource, .defaultMode)
        observers[pid] = (observer, runLoopSource, retainedSelf)
    }

    private func removeObserver(for pid: pid_t) {
        guard let entry = observers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetCurrent(), entry.runLoopSource, .defaultMode)
        _ = Unmanaged<FocusEventMonitor>.fromOpaque(entry.retainedSelf)
    }

    private func removeAllObservers() {
        for (pid, _) in observers {
            removeObserver(for: pid)
        }
        observers.removeAll()
    }

    private func handleAXNotification(element: AXUIElement, name: String) {
        guard name == kAXUIElementDestroyedNotification as String ||
              name == kAXWindowMiniaturizedNotification as String ||
              name == kAXApplicationHiddenNotification as String else {
            return
        }

        var pid: pid_t = 0
        guard AXUIElementGetPid(element, &pid) == .success,
              pid != 0,
              pid != ProcessInfo.processInfo.processIdentifier else {
            return
        }

        let now = Date().timeIntervalSince1970
        if now - lastCmdHAt < 0.5 {
            // Cmd+H is already handled by macOS; the app-hide notification it
            // produces would only race the system's own focus transfer.
            return
        }

        if name == kAXApplicationHiddenNotification as String {
            guard let hiddenApp = NSRunningApplication(processIdentifier: pid),
                  hiddenApp.isHidden else {
                AppLogger.notice(
                    "Skip AX \(name) — PID=\(pid) is not actually hidden"
                )
                return
            }
        }

        if name != kAXApplicationHiddenNotification as String {
            let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0
            guard pid == frontmostPID else {
                AppLogger.notice(
                    "Skip AX \(name) — PID=\(pid) not frontmost (\(frontmostPID))"
                )
                return
            }

            // Desktop Quick Look emits window destroy/minimize events from
            // Finder before the preview panel appears; they are not real
            // close/minimize actions.
            if let app = NSRunningApplication(processIdentifier: pid),
               app.bundleIdentifier == "com.apple.finder",
               isFinderDesktopNoise(pid: pid) {
                return
            }
        }

        // Finder's desktop element is destroyed and recreated in bursts (Quick
        // Look, desktop interactions), so collapse them like the other triggers.
        guard canTriggerNow() else { return }

        AppLogger.notice(
            "AX hide event: \(name) PID=\(pid) (\(NSRunningApplication(processIdentifier: pid)?.localizedName ?? "?"))"
        )

        let context = FocusTriggerContext(
            kind: .windowHidden,
            sourcePID: pid,
            targetWindowID: windowID(of: element)
        )
        schedule(context)
    }
}
