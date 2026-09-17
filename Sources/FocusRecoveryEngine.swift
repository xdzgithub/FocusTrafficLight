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

    private let checkInterval: TimeInterval = 0.025

    /// How long a strict dismissal (close / hide) may take before the trigger is
    /// abandoned as a non-dismissal.
    private let strictTimeout: TimeInterval = 0.8

    /// How long a minimize waits for the window to disappear from the on-screen
    /// list before the explicit action is trusted regardless.
    private let trustTimeout: TimeInterval = 0.1

    /// Increments on every trigger so a newer trigger supersedes an in-flight
    /// re-check instead of racing it.
    private var currentCheckToken = 0

    /// Consecutive polls that agreed a strict dismissal happened.
    ///
    /// The accessibility window list is the earliest signal for a close, but a
    /// single read can transiently miss a window, which would move focus while it
    /// is still on screen. Requiring two agreeing polls costs one interval (25ms)
    /// and removes that failure mode. A trusted minimize needs no confirmation.
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

        /// A minimize is trusted; a close/hide must be confirmed.
        var isTrustedAction: Bool {
            kind == .minimizeWindow || kind == .minimizeButton
        }
    }

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
        // any wait.
        if context.kind != .windowHidden,
           windowOrder.visibleLayer0WindowCount(ownerPID: context.sourcePID) >= 2 {
            AppLogger.notice("App still has another visible window, focus stays put")
            return
        }

        let pending = Pending(
            kind: context.kind,
            sourcePID: context.sourcePID,
            windowID: context.targetWindowID,
            windowBounds: context.targetWindowID.flatMap { snapshot.bounds(ofWindowID: $0) }
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
        let deadline = pending.isTrustedAction ? trustTimeout : strictTimeout

        if let reason {
            absentPolls = 0
            if waited >= deadline {
                if pending.isTrustedAction {
                    AppLogger.notice(
                        "Minimize not confirmed after \(Int(waited * 1000))ms (\(reason)), trusting the explicit action"
                    )
                    focusNextWindow(sourcePID: pending.sourcePID)
                } else {
                    AppLogger.notice("Still waiting for \(reason) after \(Int(waited * 1000))ms, skipping recovery")
                }
                return
            }
        } else {
            absentPolls += 1
            let confirmed = pending.isTrustedAction || absentPolls >= requiredAbsentPolls
            if confirmed {
                focusNextWindow(sourcePID: pending.sourcePID)
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
    /// Intentionally cheap: this runs in a 25ms poll loop, and the expensive
    /// accessibility read is avoided entirely for a minimize because it blocks
    /// during the minimize animation (see the type comment).
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

        if pending.isTrustedAction {
            // Only the cheap on-screen check; never the blocking accessibility read.
            return windowOrder.isWindowOnScreen(windowID: windowID) ? "window \(windowID) to minimize" : nil
        }

        // A close removes the window from the app's accessibility window list at
        // once, long before it leaves the on-screen list, so that list decides
        // when it can be read. A frame that fails to read is not evidence of
        // absence, so the slower on-screen list takes over if nothing could be
        // read. Matching a minimized window also counts as dismissed: minimizes
        // keep their entry in that list.
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

    private func focusNextWindow(sourcePID: pid_t) {
        let snapshot = windowOrder.takeSnapshot()
        let myPID = ProcessInfo.processInfo.processIdentifier

        // The source app is never a candidate: the point of the trigger is to
        // move focus away from it, and its window may briefly outlive the trigger.
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
