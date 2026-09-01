import AppKit
import CoreGraphics
import Darwin

private typealias SpaceCopyCurrentFunc = @convention(c) (Int) -> Int
private typealias CopySpacesForWindowFunc = @convention(c) (Int, Int) -> Unmanaged<CFArray>?

/// Focus recovery for explicit user window actions.
///
/// A trigger (Cmd+W / Cmd+M / traffic light click / app hide) is followed by
/// a single 50ms check that the target window has left the screen, then the
/// topmost visible app window in the current Space is activated.
final class FocusRecoveryEngine {

    private let accessibilityHelper: AccessibilityHelper

    init(accessibilityHelper: AccessibilityHelper) {
        self.accessibilityHelper = accessibilityHelper
    }

    func performRecoveryCheck(context: FocusTriggerContext) {
        guard accessibilityHelper.checkAccessibilityPermission() else { return }

        AppLogger.info(
            "Focus check triggered by \(context.kind.rawValue) — source PID=\(context.sourcePID) window=\(context.targetWindowID.map(String.init) ?? "?")"
        )

        guard targetWindowIsGone(context) else {
            AppLogger.info("Target window is still visible, skipping recovery")
            return
        }

        if context.kind == .windowHidden,
           appHasVisibleWindows(processID: context.sourcePID) {
            AppLogger.info("App still has visible windows after hidden event, skipping recovery")
            return
        }

        guard let app = findTopmostVisibleWindowApp() else {
            AppLogger.info("No visible app window to focus")
            return
        }

        AppLogger.info("Focusing: \(app.localizedName ?? "?")")
        performFocus(app: app)
    }

    // MARK: - Checking the Triggered Window Left the Screen

    private func targetWindowIsGone(_ context: FocusTriggerContext) -> Bool {
        guard let windowID = context.targetWindowID, windowID > 0 else { return true }
        return !isWindowOnScreen(windowID: windowID)
    }

    private func isWindowOnScreen(windowID: Int) -> Bool {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return true
        }
        return list.contains { ($0[kCGWindowNumber as String] as? Int) == windowID }
    }

    private func appHasVisibleWindows(processID: pid_t) -> Bool {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return false
        }
        return list.contains {
            ($0[kCGWindowLayer as String] as? Int) == 0 &&
            ($0[kCGWindowOwnerPID as String] as? pid_t) == processID
        }
    }

    // MARK: - Topmost Visible Window Discovery

    private func findTopmostVisibleWindowApp() -> NSRunningApplication? {
        guard let windowList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] else {
            return nil
        }

        let myPID = ProcessInfo.processInfo.processIdentifier

        for cgWindow in windowList {
            guard let layer = cgWindow[kCGWindowLayer as String] as? Int, layer == 0 else { continue }
            guard windowIsInCurrentSpace(windowInfo: cgWindow) else { continue }
            guard let ownerPID = cgWindow[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID != myPID else { continue }
            guard let app = NSRunningApplication(processIdentifier: ownerPID) else { continue }

            return app
        }

        return nil
    }

    // MARK: - Focus Transfer

    private func performFocus(app: NSRunningApplication) {
        app.activate(options: [.activateIgnoringOtherApps])
    }

    // MARK: - Space / CGWindow Helpers

    private func getCurrentSpaceID() -> Int? {
        guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/Versions/Current/CoreGraphics", RTLD_NOW) else {
            return nil
        }
        defer { dlclose(handle) }

        guard let sym = dlsym(handle, "CGSSpaceCopyCurrent"),
              let fn = unsafeBitCast(sym, to: Optional<SpaceCopyCurrentFunc>.self) else {
            return nil
        }

        let currentSpace = fn(2)
        if currentSpace != 0 {
            return currentSpace
        }
        return nil
    }

    private func windowIsInCurrentSpace(windowInfo: [String: Any]) -> Bool {
        guard let spaceID = getCurrentSpaceID() else {
            return true
        }

        guard let windowNumber = windowInfo[kCGWindowNumber as String] as? Int else {
            return false
        }

        guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/Versions/Current/CoreGraphics", RTLD_NOW) else {
            return true
        }
        defer { dlclose(handle) }

        guard let sym = dlsym(handle, "CGSCopySpacesForWindow"),
              let fn = unsafeBitCast(sym, to: Optional<CopySpacesForWindowFunc>.self) else {
            return true
        }

        guard let spacesRef = fn(2, windowNumber) else {
            return false
        }

        let spaces = spacesRef.takeRetainedValue() as! [Int]
        return spaces.contains(spaceID)
    }
}
