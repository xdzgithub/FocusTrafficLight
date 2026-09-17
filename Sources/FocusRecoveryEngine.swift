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

    /// Upper bound on the wait. Sized to comfortably exceed the slowest signal a
    /// dismissal can produce, rather than to be tight: a genuine dismissal is
    /// detected as soon as its signal arrives, so this only decides how long a
    /// non-dismissal is polled before being dropped. Measured worst cases: a
    /// minimize flag flips by ~360ms and a close's accessibility entry clears by
    /// ~225ms, both well inside this.
    private let dismissalTimeout: TimeInterval = 1.2

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
        /// The app's accessibility window count when the trigger fired, for the
        /// hide path (see `dismissalOutcome`).
        let initialWindowCount: Int?

        // A minimize keeps its accessibility entry for the whole animation, so it
        // is decided from the minimized flag (see `dismissalOutcome`).
        var isMinimize: Bool {
            kind == .minimizeWindow || kind == .minimizeButton
        }

        /// Only a genuine app-hide notification is decided from the app's window
        /// count. A minimize whose window ID could not be resolved must not fall
        /// through to it: minimizing does not change the count, so it would always
        /// time out and skip recovery.
        var isAppHide: Bool {
            kind == .windowHidden
        }
    }

    /// What the poll concluded.
    private enum DismissalOutcome {
        /// The window really went away: focus the next one.
        case dismissed
        /// The app kept windows, so focus does not need to move. Decided, not an
        /// error — stop without waiting further.
        case hold(reason: String)
        /// Not yet known; keep polling until the bound.
        case pending(reason: String)
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
            displayID: triggeredDisplay,
            initialWindowCount: context.kind == .windowHidden
                ? windowOrder.accessibilityWindows(ownerPID: context.sourcePID)?.count
                : nil
        )

        wait(pending: pending, token: token, waited: 0)
    }

    // MARK: - Waiting for the Acted-On Window to Be Dismissed

    private func wait(pending: Pending, token: Int, waited: TimeInterval) {
        // A newer trigger owns the decision now.
        guard token == currentCheckToken else { return }

        switch dismissalOutcome(pending) {
        case .hold(let reason):
            AppLogger.notice("Not recovering — \(reason)")
            return

        case .dismissed:
            absentPolls += 1
            if absentPolls >= requiredAbsentPolls {
                focusNextWindow(sourcePID: pending.sourcePID, onDisplay: pending.displayID)
                return
            }

        case .pending(let reason):
            absentPolls = 0
            guard waited < dismissalTimeout else {
                AppLogger.notice("Still waiting for \(reason) after \(Int(waited * 1000))ms, skipping recovery")
                return
            }
        }

        let interval = checkInterval
        DispatchQueue.main.asyncAfter(deadline: .now() + interval) { [weak self] in
            self?.wait(pending: pending, token: token, waited: waited + interval)
        }
    }

    /// Decides whether the acted-on window is gone.
    ///
    /// Kept cheap: this runs in a poll loop, so it does one narrow query per call.
    private func dismissalOutcome(_ pending: Pending) -> DismissalOutcome {
        // Each kind is decided from the signal that actually reports it. They are
        // not interchangeable: a minimize leaves the app's window count unchanged,
        // and a hide keeps the window's own identity unavailable.
        if pending.isMinimize {
            return minimizeOutcome(pending)
        }

        let windowID = pending.windowID ?? 0
        guard windowID > 0 else {
            return appHideOutcome(pending)
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
                if AXGeometry.isMinimized(window) { return .dismissed }
                return .pending(reason: "window \(windowID) to be dismissed")
            }
            if readableFrames > 0 { return .dismissed }
        }
        return windowOrder.isWindowOnScreen(windowID: windowID)
            ? .pending(reason: "window \(windowID) to be dismissed")
            : .dismissed
    }

    /// Decides a minimize from the accessibility minimized flag.
    ///
    /// This is the earliest reliable signal: the flag flips at ~120–360ms
    /// (measured on Finder), whereas the window does not leave the on-screen list
    /// until ~725–940ms. Waiting for the on-screen list made recovery intermittent,
    /// because a slow minimize could overrun the timeout and the trigger was then
    /// dropped.
    private func minimizeOutcome(_ pending: Pending) -> DismissalOutcome {
        // The window is known: read its own flag.
        if let bounds = pending.windowBounds, bounds.width > 0, bounds.height > 0,
           let minimized = windowOrder.windowIsMinimized(ownerPID: pending.sourcePID, matching: bounds) {
            return minimized ? .dismissed : .pending(reason: "window to be minimized")
        }

        // The window is unknown (a keyboard minimize whose window ID could not be
        // resolved), so fall back to any minimized window of that app. The later
        // on-screen check is deliberately not used here — that is the slow signal
        // this path exists to avoid.
        if let anyMinimized = windowOrder.anyWindowIsMinimized(ownerPID: pending.sourcePID) {
            return anyMinimized ? .dismissed : .pending(reason: "PID \(pending.sourcePID) to minimize a window")
        }

        // The flag could not be read at all; the on-screen list is all that is left.
        if let windowID = pending.windowID, windowID > 0 {
            return windowOrder.isWindowOnScreen(windowID: windowID)
                ? .pending(reason: "window \(windowID) to minimize")
                : .dismissed
        }
        return .pending(reason: "PID \(pending.sourcePID) to minimize a window")
    }

    /// Decides an app-hide trigger from the app's window count alone.
    ///
    /// This deliberately ignores the on-screen list, which only clears once the
    /// hide/close animation finishes (~400ms for WeChat) even though the app has
    /// already given the window up. The accessibility window count drops as soon
    /// as the window is gone (~140ms), so waiting on it roughly triples the
    /// responsiveness.
    ///
    /// Reading the count rather than just "are there any windows left" also keeps
    /// the false positives out that this path used to need both signals for: a
    /// dismissed menu or panel leaves the app's window count unchanged, so it can
    /// never be mistaken for a window going away.
    private func appHideOutcome(_ pending: Pending) -> DismissalOutcome {
        let pid = pending.sourcePID

        guard pending.isAppHide else {
            // A close whose window ID is unknown. The accessibility window list is
            // the early signal here too: a closed window leaves it well before it
            // leaves the on-screen list.
            if let windows = windowOrder.accessibilityWindows(ownerPID: pid), windows.isEmpty {
                return .dismissed
            }
            return .pending(reason: "PID \(pid) to lose its window")
        }

        guard let current = windowOrder.accessibilityWindows(ownerPID: pid)?.count else {
            // The app's window list cannot be read; fall back to the slower
            // on-screen signal rather than guessing.
            return windowOrder.visibleLayer0WindowCount(ownerPID: pid) == 0
                ? .dismissed
                : .pending(reason: "PID \(pid) to lose its windows")
        }

        let initial = pending.initialWindowCount ?? current
        if current == 0 {
            // No windows left: the app really gave its window up.
            return .dismissed
        }
        if current < initial {
            // A window went away but the app kept others, so focus does not need
            // to move. Decided now instead of waiting out the bound.
            return .hold(reason: "PID \(pid) still has \(current) window(s)")
        }
        return .pending(reason: "PID \(pid) to give up a window (has \(current))")
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
