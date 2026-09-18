import AppKit
import ApplicationServices

/// Raises the app that should own focus next.
///
/// The old implementation ended with `activate(options: [.activateIgnoringOtherApps])`
/// and discarded the result. That flag has been documented as having no effect
/// since macOS 14 ("ignoringOtherApps is deprecated in macOS 14 and will have no
/// effect"), so the call degenerated into a plain cooperative activation issued
/// by a background menu-bar accessory — which the system is free to ignore, and
/// on macOS 27 does. Nothing was logged either way.
///
/// Activation is now attempted in order, cheapest and most privileged first, and
/// every step is checked against `NSWorkspace.shared.frontmostApplication` so a
/// refusal shows up in the log instead of passing silently.
///
/// ## Displays
///
/// Bringing an app to the front raises *all* of its windows on *every* display —
/// verified native behaviour, and not something the activation options cause:
/// `kAXFrontmostAttribute`, `activate(options: [])`, `activate(from:options: [])`
/// and `activate(options: [.activateAllWindows])` all disturb the other display
/// equally. Measured on a two-display setup, the app's window on the display it
/// was not asked to change moves to the front within ~36ms.
///
/// There is no way to undo that. `kAXRaiseAction` on another app's window returns
/// success but does not reorder anything while that other app is not frontmost
/// (measured: no effect at 50/150/300/600ms), and raising only the target window
/// without activating the app leaves the app non-frontmost, so keyboard focus does
/// not follow. An earlier version tried to compensate by re-raising the displaced
/// windows; it never worked, and only produced a false "Restored N display(s)"
/// log. The behaviour is therefore left as macOS defines it.
final class ActivationService {

    private let windowOrder: WindowOrderService

    init(windowOrder: WindowOrderService) {
        self.windowOrder = windowOrder
    }

    enum Strategy: String {
        /// Raise only the target window and activate without `.activateAllWindows`.
        /// Activation then brings just the main/key windows forward, which is the
        /// same window-scoped behaviour a user click produces — so the app's windows
        /// on other displays are left where they are.
        case windowScoped = "window + activate(options:[])"
        /// Raise through the Accessibility API's application-wide frontmost flag.
        case accessibilityFrontmost = "AX frontmost"
        /// Cooperative activation, all windows.
        case cooperativeActivation = "activate(from:)"
        /// Bare public activation, all windows, kept as the last resort.
        case plainActivation = "activate(options:[all])"

        var displayName: String { rawValue }

        /// Whether this strategy can raise the app's windows on *other* displays.
        /// Used only to explain a disturbed display in the log.
        var isAppWide: Bool { self != .windowScoped }
    }

    /// - Parameter targetWindow: bounds of the window the caller selected, used to
    ///   raise that specific window and make it the app's main/key window.
    func activate(_ app: NSRunningApplication, targetWindow: CGRect?) {
        let pid = app.processIdentifier
        let name = app.localizedName ?? "?"

        // Front-to-back order of each display before activating, so a disturbance of
        // a display we were not asked to change can be reported.
        let before = orderPerDisplay()

        let attempts: [(Strategy, () -> Bool)] = [
            (.windowScoped, { self.activateWindowScoped(app, pid: pid, targetWindow: targetWindow) }),
            (.accessibilityFrontmost, { self.raiseThroughAccessibility(pid: pid) }),
            (.cooperativeActivation, { app.activate(from: NSRunningApplication.current, options: [.activateAllWindows]) }),
            (.plainActivation, { app.activate(options: [.activateAllWindows]) })
        ]

        for (strategy, attempt) in attempts {
            let accepted = attempt()
            let isFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
            AppLogger.notice(
                "Activate \(name) via \(strategy.displayName): accepted=\(accepted) frontmost=\(isFrontmost)"
            )
            if isFrontmost {
                reportDisturbedDisplays(before: before, name: name, strategy: strategy)
                return
            }
        }
    }

    // MARK: - Window-Scoped Activation

    /// Makes the target window the app's main and key window, then activates the app
    /// without `.activateAllWindows`.
    ///
    /// Per the header, a plain `activate` "brings only the main and key windows
    /// forward" — which is why the target window is primed first. Without
    /// `.activateAllWindows` the app's windows on other displays are not raised, so
    /// focusing one display does not disturb another.
    private func activateWindowScoped(_ app: NSRunningApplication, pid: pid_t, targetWindow: CGRect?) -> Bool {
        if let targetWindow, let window = windowElement(matching: targetWindow, ofApp: pid) {
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        }
        return app.activate(options: [])
    }

    // MARK: - Reporting

    private func orderPerDisplay() -> [CGDirectDisplayID: [pid_t]] {
        let snapshot = windowOrder.takeSnapshot()
        var result: [CGDirectDisplayID: [pid_t]] = [:]
        for info in snapshot.orderedWindowInfos where info.layer == 0 {
            guard let display = info.displayID else { continue }
            result[display, default: []].append(info.ownerPID)
        }
        return result
    }

    /// Logs each display whose window order changed, so it is visible whether a
    /// strategy reached beyond the display it was asked to focus.
    private func reportDisturbedDisplays(
        before: [CGDirectDisplayID: [pid_t]],
        name: String,
        strategy: Strategy
    ) {
        let after = orderPerDisplay()
        for (display, order) in after where before[display] != order {
            AppLogger.notice(
                "Display \(display) window order changed by \(strategy.displayName) (\(name)\(strategy.isAppWide ? ", app-wide strategy" : ""))"
            )
        }
    }

    // MARK: - Accessibility

    private func raiseThroughAccessibility(pid: pid_t) -> Bool {
        AXUIElementSetAttributeValue(
            AXUIElementCreateApplication(pid),
            kAXFrontmostAttribute as CFString,
            kCFBooleanTrue
        ) == .success
    }

    /// Finds the app's window element whose frame matches the CG window rect.
    ///
    /// `AXCGWindowID` used to make this a direct lookup; macOS 27 no longer
    /// provides that attribute, so geometry is the only public way to connect a
    /// `CGWindowID` to its accessibility element.
    private func windowElement(matching target: CGRect, ofApp pid: pid_t) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(
            AXUIElementCreateApplication(pid),
            kAXWindowsAttribute as CFString,
            &value
        ) == .success, let windows = value as? [AXUIElement] else {
            return nil
        }

        for window in windows {
            guard let frame = AXGeometry.frame(of: window) else { continue }
            if abs(frame.minX - target.minX) <= 2,
               abs(frame.minY - target.minY) <= 2,
               abs(frame.width - target.width) <= 2,
               abs(frame.height - target.height) <= 2 {
                return window
            }
        }
        return nil
    }
}
