import AppKit
import CoreGraphics

/// Focus recovery for explicit user window actions.
///
/// The trigger is always something the user did — `Cmd+W`, `Cmd+M`, a traffic
/// light click, or an app hiding itself — and the recovery is deliberately simple:
/// shortly after the action, hand focus to the topmost window that is not the one
/// the user just acted on.
///
/// ## Why there is no "did the window really close" check
///
/// V4 did check, once, 50ms after the trigger. On macOS 27 that check can no
/// longer work: it read the private `AXCGWindowID` attribute, which the OS has
/// removed, so the window ID was always empty and the check always answered
/// "gone". V4 was therefore, in practice, focusing unconditionally 50ms after the
/// trigger — which is exactly the behaviour reproduced here.
///
/// A real check cannot be both fast and correct, because the window does not
/// leave the screen until its animation finishes: measured ~140ms for a Finder
/// close, ~225ms for Chrome, and ~660ms for a minimize. Verifying it would force
/// a wait longer than the 50ms target. The user's action is taken as the intent
/// instead.
///
/// ## What is still filtered
///
/// - the source app never becomes the candidate (focus is moving *away* from it);
/// - a close/minimize that leaves the app with another window on the same display
///   does nothing, since focus does not need to move;
/// - a next window on the same display is preferred, so acting on one screen does
///   not push focus to another;
/// - the source app's window list is not consulted at all, so no per-app
///   accessibility latency is on the path.
///
/// macOS 27 notes: the private `CGSSpaceCopyCurrent` / `CGSCopySpacesForWindow`
/// symbols are gone and `AXCGWindowID` no longer identifies a window, so Space
/// filtering and window ordering come from `WindowOrderService` (public API).
final class FocusRecoveryEngine {

    private let accessibilityHelper: AccessibilityHelper
    private let windowOrder: WindowOrderService
    private let activation: ActivationService

    /// Increments on every trigger so a newer trigger supersedes an older one
    /// instead of the two racing.
    private var currentCheckToken = 0

    init(accessibilityHelper: AccessibilityHelper) {
        self.accessibilityHelper = accessibilityHelper
        self.windowOrder = WindowOrderService()
        self.activation = ActivationService(windowOrder: WindowOrderService())
    }

    func performRecoveryCheck(context: FocusTriggerContext) {
        currentCheckToken += 1

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

        focusNextWindow(sourcePID: context.sourcePID, onDisplay: triggeredDisplay)
    }

    private func focusNextWindow(sourcePID: pid_t, onDisplay displayID: CGDirectDisplayID?) {
        let snapshot = windowOrder.takeSnapshot()
        let myPID = ProcessInfo.processInfo.processIdentifier

        // The source app is never a candidate: the point of the trigger is to
        // move focus away from it.
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
