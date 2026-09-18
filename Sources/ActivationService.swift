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

    /// - Parameter targetWindow: bounds of the window the caller selected, used to
    ///   raise that specific window when it can be matched in the target app.
    func activate(_ app: NSRunningApplication, targetWindow: CGRect?) {
        let pid = app.processIdentifier
        let name = app.localizedName ?? "?"

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
