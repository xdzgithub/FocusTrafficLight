import AppKit
import CoreGraphics

/// Focus recovery for explicit user window actions.
///
/// The trigger is always something the user did — `Cmd+W`, `Cmd+M`, a traffic
/// light click, or an app hiding itself — and recovery waits for evidence that the
/// acted-on window actually went away before moving focus.
///
/// ## Why the wait is real but short
///
/// The window stays on screen until its animation finishes, so the evidence
/// cannot arrive immediately: measured on macOS 27, ~140ms for a Finder close,
/// ~225ms for Chrome, and ~660ms for a minimize (its genie animation). Two things
/// keep the latency at the signal's own speed rather than the bound's:
///
///   * a 15ms poll interval, so focus moves within one interval of the signal;
///   * the bound only governs how long a window that is *not* being dismissed is
///     waited on. A browser tab closing never produces the signal, so it waits out
///     the bound and is then correctly skipped — its own cost is invisible, since
///     no focus change was going to happen anyway.
///
/// ## Why the evidence differs by dismissal kind
///
/// | action   | what proves it happened                                  |
/// |----------|----------------------------------------------------------|
/// | close    | the window leaves the app's accessibility window list      |
/// | minimize | the window leaves the on-screen list (it keeps its         |
/// |          | accessibility entry, only gaining a minimized flag)        |
/// | hide     | the app loses its windows                                  |
///
/// The accessibility list is the earlier signal for a close (~140–225ms versus
/// ~570ms on-screen), which is why it drives that case. During a minimize the
/// app's accessibility server stops answering for ~500ms, so the on-screen list
/// is used there instead.
///
/// macOS 27 notes: the private `CGSSpaceCopyCurrent` / `CGSCopySpacesForWindow`
/// symbols are gone and `AXCGWindowID` no longer identifies a window, so Space
/// filtering and window ordering come from `WindowOrderService` (public API).
final class FocusRecoveryEngine {

    private let accessibilityHelper: AccessibilityHelper
    private let windowOrder: WindowOrderService
    private let activation: ActivationService

    private let checkInterval: TimeInterval = 0.015

    /// Upper bound on the wait. Sized to comfortably exceed the slowest dismissal
    /// (a minimize animation at ~660ms) rather than to be tight: a genuine
    /// dismissal is detected as soon as its signal arrives, so this only decides
    /// how long a non-dismissal is polled before being dropped.
    private let dismissalTimeout: TimeInterval = 1.0

    /// Increments on every trigger so a newer trigger supersedes an in-flight
    /// re-check instead of racing it.
    private var currentCheckToken = 0

    /// Consecutive polls that agreed the dismissal happened.
    ///
    /// A single read can transiently miss a window, which would move focus while
    /// it is still on screen. Confirming on the next interval costs 15ms.
    private var absentPolls = 0
    private let requiredAbsentPolls = 2

    /// What the current trigger is waiting for.
    private struct Pending {
        let kind: FocusTriggerContext.Kind
        let sourcePID: pid_t
        let windowID: Int?
        /// Bounds captured at trigger time, used to recognise the window in the
        /// source app's accessibility list.
        let windowBounds: CGRect?
        /// The display the acted-on window was on, captured at trigger time before
        /// it leaves the screen. Recovery prefers a next window on the same
        /// display, so acting on one screen does not hand focus to another. nil for
        /// an app-hide trigger, which carries no window.
        let displayID: CGDirectDisplayID?

        /// A minimize keeps its accessibility entry for the whole animation, so it
        /// is decided from the on-screen list alone (see `dismissalPendingReason`).
        var isMinimize: Bool {
            kind == .minimizeWindow || kind == .minimizeButton
        }
    }

    init(accessibilityHelper: AccessibilityHelper) {
        self.accessibilityHelper = accessibilityHelper
        self.windowOrder = WindowOrderService()
        self.activation = ActivationService(windowOrder: WindowOrderService())
    }

    func performRecoveryCheck(context: FocusTriggerContext) {
        currentCheckToken += 1
        let token = currentCheckToken
        absentPolls = 0

        AppLogger.notice(
            "Focus check triggered by \(context.kind.rawValue) — source PID=\(context.sourcePID) window=\(context.targetWindowID.map(String.init) ?? "?")"
        )

        guard accessibilityHelper.checkAccessibilityPermission() else {
            AppLogger.notice("Focus check skipped — Accessibility permission not granted")
            return
        }

        let snapshot = windowOrder.takeSnapshot()
        if !snapshot.isSpaceFiltered {
            AppLogger.notice(
                "Window z-order is not Space-filtered — NSWindow.windowNumbers returned nothing, falling back to CGWindowList"
            )
        }

        // Which display the user is working on, taken while the acted-on window is
        // still on screen. An app-hide trigger carries no window ID, so the source
        // app's own frontmost window stands in for it; without this the display
        // would be unknown and focus could land on the other screen.
        let triggeredDisplay: CGDirectDisplayID? = {
            if let windowID = context.targetWindowID, let display = snapshot.info(forWindowID: windowID)?.displayID {
                return display
            }
            return snapshot.topmostWindow(ownerPID: context.sourcePID)?.displayID
        }()
        if let triggeredDisplay {
            AppLogger.notice("Triggered window is on display \(triggeredDisplay)")
        } else {
            AppLogger.notice("Triggered window's display unknown, using global z-order")
        }

        // Acting on one of several windows leaves the app present on that display,
        // so focus does not need to move. Instant decision, no waiting.
        if context.kind != .windowHidden, let myWindow = context.targetWindowID, myWindow > 0 {
            let stillHasWindowHere = triggeredDisplay.map {
                windowOrder.hasOtherVisibleLayer0Window(
                    ownerPID: context.sourcePID, onDisplay: $0, excluding: myWindow
                )
            } ?? (windowOrder.visibleLayer0WindowCount(ownerPID: context.sourcePID) >= 2)
            if stillHasWindowHere {
                AppLogger.notice("App still has another window on this display, focus stays put")
                return
            }
        } else if context.kind != .windowHidden,
                  windowOrder.visibleLayer0WindowCount(ownerPID: context.sourcePID) >= 2 {
            AppLogger.notice("App still has another visible window, focus stays put")
            return
        }

        let pending = Pending(
            kind: context.kind,
            sourcePID: context.sourcePID,
            windowID: context.targetWindowID,
            windowBounds: context.targetWindowID.flatMap { snapshot.bounds(ofWindowID: $0) },
            displayID: triggeredDisplay
        )

        wait(pending: pending, token: token, waited: 0)
    }

    // MARK: - Waiting for the Acted-On Window to Be Dismissed

    private func wait(pending: Pending, token: Int, waited: TimeInterval) {
        // A newer trigger owns the decision now.
        guard token == currentCheckToken else { return }

        let reason = dismissalPendingReason(pending)

        if let reason {
            absentPolls = 0
            guard waited < dismissalTimeout else {
                AppLogger.notice("Still waiting for \(reason) after \(Int(waited * 1000))ms, skipping recovery")
                return
            }
        } else {
            absentPolls += 1
            if absentPolls >= requiredAbsentPolls {
                focusNextWindow(sourcePID: pending.sourcePID, onDisplay: pending.displayID)
                return
            }
        }

        let interval = checkInterval
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) { [weak self] in
            self?.wait(pending: pending, token: token, waited: waited + interval)
        }
    }

    /// Returns what we are still waiting for, or nil once the window is dismissed.
    ///
    /// Kept cheap: this runs in a 15ms poll loop, so it does one narrow query per
    /// call.
    private func dismissalPendingReason(_ pending: Pending) -> String? {
        guard let windowID = pending.windowID, windowID > 0 else {
            // An app-hide trigger carries no window ID: the accessibility element is
            // destroyed before the notification arrives, so its frame — and hence its
            // window ID — can no longer be read. Wait on the app losing its windows,
            // requiring both signals to clear, so the engine neither fires while a
            // window is still visible nor concludes "still there" when only the
            // slower on-screen list has caught up.
            if let windows = windowOrder.accessibilityWindows(ownerPID: pending.sourcePID), !windows.isEmpty {
                return "PID \(pending.sourcePID) to lose its windows"
            }
            return windowOrder.visibleLayer0WindowCount(ownerPID: pending.sourcePID) == 0
                ? nil
                : "PID \(pending.sourcePID) to lose its windows"
        }

        // A minimize keeps its accessibility entry (marked minimized) for the whole
        // genie animation and only leaves the on-screen list at ~660ms — which is
        // also when the animation finishes, so waiting for that is what keeps focus
        // from being stolen mid-animation. The on-screen check is used exclusively:
        // during the animation the app's accessibility server stops answering.
        if pending.isMinimize {
            return windowOrder.isWindowOnScreen(windowID: windowID) ? "window \(windowID) to minimize" : nil
        }

        // A close removes the window from the app's accessibility window list at
        // once, well before it leaves the on-screen list, so that list decides when
        // it can be read. A frame that fails to read is not evidence of absence, so
        // the slower on-screen list takes over if nothing could be read. A matching
        // window that is minimized also counts as dismissed.
        if let windows = windowOrder.accessibilityWindows(ownerPID: pending.sourcePID),
           let bounds = pending.windowBounds, bounds.width > 0, bounds.height > 0 {
            var readableFrames = 0
            for window in windows {
                guard let frame = AXGeometry.frame(of: window) else { continue }
                readableFrames += 1
                guard abs(frame.minX - bounds.minX) <= 2, abs(frame.minY - bounds.minY) <= 2,
                      abs(frame.width - bounds.width) <= 2, abs(frame.height - bounds.height) <= 2 else {
                    continue
                }
                if AXGeometry.isMinimized(window) { return nil }
                return "window \(windowID) to be dismissed"
            }
            if readableFrames > 0 { return nil }
        }
        return windowOrder.isWindowOnScreen(windowID: windowID) ? "window \(windowID) to be dismissed" : nil
    }

    private func focusNextWindow(sourcePID: pid_t, onDisplay displayID: CGDirectDisplayID?) {
        let snapshot = windowOrder.takeSnapshot()
        let myPID = ProcessInfo.processInfo.processIdentifier

        // The source app is never a candidate: the point of the trigger is to
        // move focus away from it, and its window may briefly outlive the trigger.
        var excluded: Set<pid_t> = [myPID]
        if sourcePID != 0 { excluded.insert(sourcePID) }

        guard let candidate = snapshot.topmostWindow(excluding: excluded, preferringDisplay: displayID),
              let app = NSRunningApplication(processIdentifier: candidate.ownerPID) else {
            AppLogger.notice("No visible app window to focus")
            return
        }

        let onRequestedDisplay = displayID != nil && candidate.displayID == displayID
        AppLogger.notice(
            "Focusing: \(app.localizedName ?? "?") window=\(candidate.windowID)\(displayID == nil ? "" : " onDisplay=\(onRequestedDisplay ? "same" : "other")")"
        )
        activation.activate(app, targetWindow: candidate.bounds, targetDisplay: candidate.displayID)
    }
}
