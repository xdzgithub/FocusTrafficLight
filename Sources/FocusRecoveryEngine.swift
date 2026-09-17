import AppKit
import CoreGraphics

/// Focus recovery for explicit user window actions.
///
/// A trigger (Cmd+W / Cmd+M / traffic light click / app hide) decides whether the
/// window the user acted on is really gone, then activates the topmost visible
/// app window in the current Space.
///
/// macOS 27 notes: the private `CGSSpaceCopyCurrent` / `CGSCopySpacesForWindow`
/// symbols are gone and `AXCGWindowID` no longer identifies a window, so Space
/// filtering and window ordering come from `WindowOrderService` (public API).
///
/// ## Why the three dismissal kinds are handled differently
///
/// Measured on macOS 27, each kind reports itself at a very different time and
/// through a different channel:
///
/// | action   | earliest signal                                   |
/// |----------|---------------------------------------------------|
/// | close    | window leaves the AX window list at ~281ms        |
/// | minimize | window keeps its AX entry (marked minimized)      |
/// | hide     | AX destroy notification at ~130ms                 |
///
/// Reading the AX window list is what makes a close fast — the on-screen list
/// only reflects it at ~569ms. A minimize is the awkward one: during its
/// animation the target's accessibility server stops answering, so that same
/// read *blocks* for ~515ms, and the window only leaves the on-screen list at
/// ~659ms. Neither channel is both fast and safe, so a minimize — an
/// unambiguous instruction aimed at the frontmost window — is trusted after a
/// short grace period instead of being verified to completion. A close is not
/// ambiguous the same way (closing a browser tab leaves the window present), so
/// it stays strict.
final class FocusRecoveryEngine {

    private let accessibilityHelper: AccessibilityHelper
    private let windowOrder: WindowOrderService
    private let activation: ActivationService

    private let checkInterval: TimeInterval = 0.015

    /// How long a close or hide may take before the trigger is abandoned as a
    /// non-dismissal.
    ///
    /// A real close shows up in the accessibility window list between roughly
    /// 140ms (Finder, System Settings) and 225ms (Chrome), so this bound catches
    /// it while a window that is genuinely staying — a browser tab closing, a
    /// menu dismissing — stops waiting quickly instead of hanging for a second.
    private let dismissalTimeout: TimeInterval = 0.35

    /// A minimize runs a genie animation and the window stays on screen for the
    /// whole of it, leaving only at ~660ms. Focusing earlier would steal focus
    /// mid-animation, so a minimize is allowed that long.
    private let minimizeTimeout: TimeInterval = 0.8

    /// Increments on every trigger so a newer trigger supersedes an in-flight
    /// re-check instead of racing it.
    private var currentCheckToken = 0

    /// Consecutive polls that agreed the dismissal happened.
    ///
    /// A single read can transiently miss a window, which would move focus while
    /// it is still on screen. Confirming on the next interval costs 15ms and
    /// removes that failure mode.
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
        /// The display the triggered window was on, captured at trigger time
        /// before it leaves the screen. Recovery prefers a next window on the same
        /// display, so closing a window on the second screen does not hand focus to
        /// whatever happens to be frontmost on the first. nil for an app-hide
        /// trigger, which carries no window.
        let displayID: CGDirectDisplayID?

        /// A minimize moves the window off screen through its genie animation and
        /// keeps its accessibility entry the whole time, so it is decided from the
        /// on-screen list alone (see `dismissalPendingReason`).
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

        let snapshot = windowOrder.takeSnapshot()
        if !snapshot.isSpaceFiltered {
            AppLogger.notice(
                "Window z-order is not Space-filtered — NSWindow.windowNumbers returned nothing, falling back to CGWindowList"
            )
        }

        // Which display the user is working on. Captured now, while the triggered
        // window is still on screen, because it is gone by the time focus moves.
        //
        // An app-hide trigger carries no window ID, so the source app's own
        // frontmost window is used instead: it is still on screen at this point
        // (a hide takes ~400ms while the notification arrives at ~130ms). Without
        // this the display would be unknown, recovery would fall back to the
        // global z-order, and closing a window on one screen could hand focus to
        // a window on another.
        let triggeredDisplay: CGDirectDisplayID? = {
            if let windowID = context.targetWindowID, let display = snapshot.info(forWindowID: windowID)?.displayID {
                return display
            }
            return snapshot.topmostWindow(ownerPID: context.sourcePID)?.displayID
        }()
        if let triggeredDisplay {
            AppLogger.notice("Triggered window is on display \(triggeredDisplay)")
        } else {
            AppLogger.notice("Triggered window's display unknown, falling back to global z-order")
        }

        // Closing or minimizing one of several windows leaves the app with a
        // window, so focus does not need to move at all. Deciding this now avoids
        // any wait. The check is scoped to the triggered window's display, so
        // closing the last window on one screen still hands focus on even when the
        // app keeps a window on another screen. The triggered window itself is
        // excluded: it is still on screen at this point.
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

    // MARK: - Waiting for the Triggered Window to Be Dismissed

    private func wait(pending: Pending, token: Int, waited: TimeInterval) {
        // A newer trigger owns the decision now.
        guard token == currentCheckToken else { return }

        guard accessibilityHelper.checkAccessibilityPermission() else {
            AppLogger.notice("Focus check skipped — Accessibility permission not granted")
            return
        }

        let reason = dismissalPendingReason(pending)

        if let reason {
            absentPolls = 0
            let bound = pending.isMinimize ? minimizeTimeout : dismissalTimeout
            guard waited < bound else {
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
    /// Intentionally cheap: this runs in a 25ms poll loop.
    private func dismissalPendingReason(_ pending: Pending) -> String? {
        guard let windowID = pending.windowID, windowID > 0 else {
            // An app-hide trigger carries no window ID: the accessibility element
            // is destroyed before the notification arrives, so its frame — and
            // hence its window ID — can no longer be read. Wait on the app losing
            // its windows, requiring both signals to clear, so the engine neither
            // fires while a window is still visible nor concludes "still there"
            // when only the slower on-screen list has caught up.
            if let windows = windowOrder.accessibilityWindows(ownerPID: pending.sourcePID), !windows.isEmpty {
                return "PID \(pending.sourcePID) to lose its windows"
            }
            return windowOrder.visibleLayer0WindowCount(ownerPID: pending.sourcePID) == 0
                ? nil
                : "PID \(pending.sourcePID) to lose its windows"
        }

        // A minimize keeps its accessibility entry (marked minimized) and stays in
        // the on-screen list for the whole genie animation, leaving it only at
        // ~659ms — which is also when the animation finishes, so focusing then
        // cannot jump ahead of it. The on-screen check is used exclusively here:
        // during the animation the app's accessibility server stops answering, so
        // a window list read would block for ~515ms.
        if pending.isMinimize {
            return windowOrder.isWindowOnScreen(windowID: windowID) ? "window \(windowID) to minimize" : nil
        }

        // A close removes the window from the app's accessibility window list at
        // once, long before it leaves the on-screen list, so that list decides
        // when it can be read. A frame that fails to read is not evidence of
        // absence, so the slower on-screen list takes over if nothing could be
        // read. A matching window that is minimized also counts as dismissed.
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
