import AppKit
import CoreGraphics

/// Focus recovery for explicit user window actions.
///
/// A trigger (Cmd+W / Cmd+M / traffic light click / app hide) waits for the
/// triggered window to disappear, then activates the topmost visible app window
/// in the current Space.
///
/// Why waiting is required: the window-out signal always trails the user action.
/// Measured on macOS 27, a Finder close is visible in the accessibility window
/// list at ~281ms but does not leave the on-screen list until ~569ms, and the
/// accessibility "window destroyed" notification for a WeChat hide arrives at
/// ~130ms while the window stays on screen until ~400ms. Firing immediately
/// would therefore have to guess, which is exactly what made v4.x skip every
/// recovery (it sampled once at 50ms and concluded the window was still there).
///
/// The wait is kept short in three ways:
///   * an instant skip when the source app still has another window, since
///     closing one of several windows needs no focus change at all;
///   * polling every 25ms, so the decision lands within one interval of the
///     earliest available signal;
///   * preferring the accessibility window list over the on-screen list, as it
///     reflects the close/hide about twice as early.
///
/// macOS 27 notes: the private `CGSSpaceCopyCurrent` / `CGSCopySpacesForWindow`
/// symbols are gone and `AXCGWindowID` no longer identifies a window, so Space
/// filtering and window ordering come from `WindowOrderService` (public API).
final class FocusRecoveryEngine {

    private let accessibilityHelper: AccessibilityHelper
    private let windowOrder: WindowOrderService
    private let activation: ActivationService

    /// How long to keep re-checking before deciding the window is staying.
    private let settleTimeout: TimeInterval = 0.8
    private let checkInterval: TimeInterval = 0.025

    /// Increments on every trigger so a newer trigger supersedes an in-flight
    /// re-check instead of racing it.
    private var currentCheckToken = 0

    /// What the current trigger is waiting for.
    private struct Pending {
        let kind: FocusTriggerContext.Kind
        let sourcePID: pid_t
        let windowID: Int?
        /// Bounds captured at trigger time, used to recognise the window in the
        /// source app's accessibility list.
        let windowBounds: CGRect?
    }

    /// Consecutive polls that agreed the window is gone.
    ///
    /// The accessibility window list is the earliest signal, so it drives the
    /// decision — but a single read can transiently miss a window, which would
    /// move focus while it is still on screen. Requiring two consecutive agreeing
    /// polls costs one 25ms interval and removes that failure mode.
    private var absentPolls = 0
    private let requiredAbsentPolls = 2

    init(accessibilityHelper: AccessibilityHelper) {
        self.accessibilityHelper = accessibilityHelper
        self.windowOrder = WindowOrderService()
        self.activation = ActivationService()
    }

    func performRecoveryCheck(context: FocusTriggerContext) {
        currentCheckToken += 1
        let token = currentCheckToken
        absentPolls = 0

        AppLogger.notice(
            "Focus check triggered by \(context.kind.rawValue) — source PID=\(context.sourcePID) window=\(context.targetWindowID.map(String.init) ?? "?")"
        )

        let snapshot = windowOrder.takeSnapshot()
        if !snapshot.isSpaceFiltered {
            AppLogger.notice(
                "Window z-order is not Space-filtered — NSWindow.windowNumbers returned nothing, falling back to CGWindowList"
            )
        }

        // Closing or minimizing one of several windows leaves the app with a
        // window, so focus does not need to move at all. Deciding this now avoids
        // the wait entirely.
        if context.kind != .windowHidden {
            let remaining = windowOrder.visibleLayer0WindowCount(ownerPID: context.sourcePID)
            if remaining >= 2 {
                AppLogger.notice("App still has \(remaining) visible windows, focus stays put")
                return
            }
        }

        let pending = Pending(
            kind: context.kind,
            sourcePID: context.sourcePID,
            windowID: context.targetWindowID,
            windowBounds: context.targetWindowID.flatMap { snapshot.bounds(ofWindowID: $0) }
        )

        waitForWindowToGo(pending: pending, token: token, waited: 0)
    }

    // MARK: - Waiting for the Triggered Window to Disappear

    private func waitForWindowToGo(pending: Pending, token: Int, waited: TimeInterval) {
        // A newer trigger owns the decision now.
        guard token == currentCheckToken else { return }

        guard accessibilityHelper.checkAccessibilityPermission() else {
            AppLogger.notice("Focus check skipped — Accessibility permission not granted")
            return
        }

        if let reason = stillPending(pending) {
            absentPolls = 0
            guard waited < settleTimeout else {
                AppLogger.notice("Still waiting for \(reason) after \(Int(waited * 1000))ms, skipping recovery")
                return
            }
            let interval = checkInterval
            DispatchQueue.main.asyncAfter(deadline: .now() + interval) { [weak self] in
                self?.waitForWindowToGo(pending: pending, token: token, waited: waited + interval)
            }
            return
        }

        absentPolls += 1
        if absentPolls < requiredAbsentPolls {
            let interval = checkInterval
            DispatchQueue.main.asyncAfter(deadline: .now() + interval) { [weak self] in
                self?.waitForWindowToGo(pending: pending, token: token, waited: waited + interval)
            }
            return
        }

        focusNextWindow(sourcePID: pending.sourcePID)
    }

    /// Returns a description of what we are still waiting for, or nil once the
    /// triggered window really is gone.
    ///
    /// Everything is derived from a single accessibility read per poll: that list
    /// reflects a close/hide roughly twice as early as the on-screen window list
    /// (measured ~281ms vs ~569ms for a Finder close), and reading it once keeps
    /// the poll cheap enough to run every 25ms.
    private func stillPending(_ pending: Pending) -> String? {
        let pid = pending.sourcePID
        let axWindows = windowOrder.accessibilityWindows(ownerPID: pid)

        if let windowID = pending.windowID, windowID > 0 {
            // The accessibility window list is the early signal, so it decides
            // when it can be read: the closed window leaves it at ~281ms while it
            // stays composited on screen until ~569ms. A frame that fails to read
            // is not evidence of absence, so the slower on-screen list takes over
            // when nothing could be read.
            if let axWindows = windowOrder.accessibilityWindows(ownerPID: pid),
               let bounds = pending.windowBounds, bounds.width > 0, bounds.height > 0 {
                var readableFrames = 0
                for window in axWindows {
                    guard let frame = AXGeometry.frame(of: window) else { continue }
                    readableFrames += 1
                    if abs(frame.minX - bounds.minX) <= 2, abs(frame.minY - bounds.minY) <= 2,
                       abs(frame.width - bounds.width) <= 2, abs(frame.height - bounds.height) <= 2 {
                        return "window \(windowID) to disappear"
                    }
                }
                if readableFrames > 0 { return nil }
            }
            return windowOrder.isWindowOnScreen(windowID: windowID) ? "window \(windowID) to disappear" : nil
        }

        // An app-hide trigger carries no window ID: the accessibility element is
        // destroyed before the notification arrives, so its frame — and hence its
        // window ID — can no longer be read. Wait on the app losing its windows,
        // requiring both signals to clear: the accessibility list is early, and
        // the on-screen list can lag it by a few hundred ms. Waiting for both
        // avoids firing while a window is still visibly there, and avoids
        // concluding "still there" when only the slower list has caught up.
        if let axWindows, !axWindows.isEmpty { return "PID \(pid) to lose its windows" }
        return windowOrder.visibleLayer0WindowCount(ownerPID: pid) == 0 ? nil : "PID \(pid) to lose its windows"
    }

    private func focusNextWindow(sourcePID: pid_t) {
        let snapshot = windowOrder.takeSnapshot()
        let myPID = ProcessInfo.processInfo.processIdentifier

        // The wait above already established that the source app's window is
        // gone, so there is no second guess here. Its PID is still excluded from
        // the candidates: the point of the trigger is to move focus away from it,
        // and its window may briefly outlive the accessibility list.
        var excluded: Set<pid_t> = [myPID]
        if sourcePID != 0 { excluded.insert(sourcePID) }

        guard let candidate = snapshot.topmostWindow(excluding: excluded),
              let app = NSRunningApplication(processIdentifier: candidate.ownerPID) else {
            AppLogger.notice("No visible app window to focus")
            return
        }

        AppLogger.notice("Focusing: \(app.localizedName ?? "?") window=\(candidate.windowID)")
        activation.activate(app, targetWindow: candidate.bounds)
    }
}
