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
final class ActivationService {

    private let windowOrder: WindowOrderService

    init(windowOrder: WindowOrderService) {
        self.windowOrder = windowOrder
    }

    enum Strategy: String {
        /// Raise through the Accessibility API. This is the only mechanism that
        /// lets an accessory process hand focus to another app, and it uses the
        /// permission this app already requires.
        case accessibilityFrontmost = "AX frontmost"
        /// Cooperative activation: the public replacement for the deprecated flag.
        case cooperativeActivation = "activate(from:)"
        /// Bare public activation, kept as the last resort.
        case plainActivation = "activate(options:)"

        var displayName: String { rawValue }
    }

    /// - Parameters:
    ///   - targetWindow: bounds of the window the caller selected, used to raise
    ///     that specific window when it can be matched in the target app.
    ///   - targetDisplay: the display the user is working on. Activation raises
    ///     the target app's windows on *every* display, so the other displays are
    ///     put back the way they were once activation settles.
    func activate(_ app: NSRunningApplication, targetWindow: CGRect?, targetDisplay: CGDirectDisplayID?) {
        let pid = app.processIdentifier
        let name = app.localizedName ?? "?"

        // Captured before activation: on each display, whatever is currently above
        // the app being activated. Restoring these afterwards keeps a display the
        // user is not working on visually unchanged.
        let displaced = displacedWindows(onOtherThan: targetDisplay, activating: pid)

        let attempts: [(Strategy, () -> Bool)] = [
            (.accessibilityFrontmost, { self.raiseThroughAccessibility(pid: pid, targetWindow: targetWindow) }),
            (.cooperativeActivation, { app.activate(from: NSRunningApplication.current, options: [.activateAllWindows]) }),
            (.plainActivation, { app.activate(options: [.activateAllWindows]) })
        ]

        for (strategy, attempt) in attempts {
            let accepted = attempt()
            let isFrontmost = NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
            AppLogger.notice(
                "Activate \(name) via \(strategy.displayName): accepted=\(accepted) frontmost=\(isFrontmost)"
            )
            if isFrontmost { break }
        }

        if displaced.isEmpty { return }

        // Restore once activation has settled; raising too early would be undone
        // by the activation still in flight.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.restore(displaced, name: name)
        }
    }

    // MARK: - Keeping Other Displays Undisturbed

    /// Windows that activation would newly cover, keyed by the display they are on.
    private func displacedWindows(
        onOtherThan targetDisplay: CGDirectDisplayID?,
        activating pid: pid_t
    ) -> [CGDirectDisplayID: WindowOrderService.WindowInfo] {
        let myPID = ProcessInfo.processInfo.processIdentifier
        let snapshot = windowOrder.takeSnapshot()
        let frontmost = snapshot.topmostWindowPerDisplay(excluding: [myPID])

        return frontmost.filter { display, window in
            // Only displays the user is not working on.
            guard display != targetDisplay else { return false }
            // Nothing to restore where the app was already on top.
            return window.ownerPID != pid
        }
    }

    private func restore(_ windows: [CGDirectDisplayID: WindowOrderService.WindowInfo], name: String) {
        let snapshot = windowOrder.takeSnapshot()
        let current = snapshot.topmostWindowPerDisplay(excluding: [])
        var restored = 0

        for (display, window) in windows {
            // Leave it alone if it never lost the top spot.
            guard current[display]?.windowID != window.windowID else { continue }
            guard let element = windowElement(matching: window.bounds, ofApp: window.ownerPID) else { continue }
            if AXUIElementPerformAction(element, kAXRaiseAction as CFString) == .success {
                restored += 1
            }
        }

        if restored > 0 {
            AppLogger.notice("Restored \(restored) display(s) not covered by \(name)")
        }
    }

    // MARK: - Accessibility

    private func raiseThroughAccessibility(pid: pid_t, targetWindow: CGRect?) -> Bool {
        let appElement = AXUIElementCreateApplication(pid)

        if let targetWindow, let window = windowElement(matching: targetWindow, ofApp: pid) {
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementSetAttributeValue(window, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        }

        return AXUIElementSetAttributeValue(
            appElement,
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
