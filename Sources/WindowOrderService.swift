import AppKit
import ApplicationServices
import CoreGraphics

/// A permission-free view of what is on screen right now.
///
/// macOS 27 removed the private `AXCGWindowID` attribute this app used to map an
/// accessibility window back to its `CGWindowID`, and the private
/// `CGSSpaceCopyCurrent` / `CGSCopySpacesForWindow` symbols it used to filter
/// windows by Space. Both jobs are now done with public API:
///
///   * `NSWindow.windowNumbers(options: [.allApplications])` lists the windows
///     visible on the *active Space* in front-to-back z-order. That ordering is
///     exactly the "topmost visible window in the current Space" rule the spec
///     asks for, so it replaces the dead CGS calls.
///   * `CGWindowListCopyWindowInfo(.optionOnScreenOnly)` supplies the owner PID,
///     layer and bounds for those window numbers. Those keys do not need Screen
///     Recording; window *titles* do, which is why nothing here reads a title.
///
/// Every query is answered from a single `Snapshot`, so one recovery check never
/// sees two different moments in time.
final class WindowOrderService {

    struct WindowInfo {
        let windowID: Int
        let ownerPID: pid_t
        let layer: Int
        let bounds: CGRect
    }

    /// One coherent look at the window server.
    struct Snapshot {
        /// Window numbers visible on the active Space, front to back.
        fileprivate let ordered: [Int]
        /// True when `ordered` came from `NSWindow` and is therefore really
        /// filtered to the active Space; false when it is the CG fallback.
        let isSpaceFiltered: Bool
        fileprivate let infoByID: [Int: WindowInfo]
        fileprivate let visible: Set<Int>

        /// The window's metadata, or nil when it is not in front of us at all.
        func info(forWindowID windowID: Int) -> WindowInfo? {
            infoByID[windowID]
        }

        /// True when the window is currently visible on the active Space.
        func isVisible(windowID: Int) -> Bool {
            visible.contains(windowID)
        }

        func ownerPID(ofWindowID windowID: Int) -> pid_t? {
            infoByID[windowID]?.ownerPID
        }

        func layer(ofWindowID windowID: Int) -> Int? {
            infoByID[windowID]?.layer
        }

        func bounds(ofWindowID windowID: Int) -> CGRect? {
            infoByID[windowID]?.bounds
        }

        /// Window numbers visible on the active Space, front to back.
        var orderedWindowIDs: [Int] { ordered }

        /// The window whose frame matches `frame`, used to map an accessibility
        /// element back to its `CGWindowID` now that `AXCGWindowID` is gone.
        func windowID(matchingFrame frame: CGRect, tolerance: CGFloat = 2) -> Int? {
            ordered.first { windowID in
                guard let bounds = infoByID[windowID]?.bounds else { return false }
                return abs(bounds.minX - frame.minX) <= tolerance &&
                    abs(bounds.minY - frame.minY) <= tolerance &&
                    abs(bounds.width - frame.width) <= tolerance &&
                    abs(bounds.height - frame.height) <= tolerance
            }
        }

        /// The frontmost normal window belonging to `pid`, or nil when that app
        /// has none in the current Space.
        func topmostWindow(ownerPID pid: pid_t) -> WindowInfo? {
            ordered.lazy
                .compactMap { infoByID[$0] }
                .first { $0.ownerPID == pid && $0.layer == 0 }
        }

        func hasVisibleWindow(ownerPID pid: pid_t) -> Bool {
            topmostWindow(ownerPID: pid) != nil
        }

        /// The frontmost normal window owned by anyone outside `excluded`.
        func topmostWindow(excluding excluded: Set<pid_t>) -> WindowInfo? {
            ordered.lazy
                .compactMap { infoByID[$0] }
                .first { !excluded.contains($0.ownerPID) && $0.layer == 0 }
        }
    }

    func takeSnapshot() -> Snapshot {
        var infoByID: [Int: WindowInfo] = [:]
        var cgOrder: [Int] = []

        let cgList = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []

        for entry in cgList {
            guard let windowID = entry[kCGWindowNumber as String] as? Int,
                  let ownerPID = entry[kCGWindowOwnerPID as String] as? pid_t else {
                continue
            }
            var bounds = CGRect.zero
            if let dict = entry[kCGWindowBounds as String] as? [String: Any],
               let rect = CGRect(dictionaryRepresentation: dict as CFDictionary) {
                bounds = rect
            }
            infoByID[windowID] = WindowInfo(
                windowID: windowID,
                ownerPID: ownerPID,
                layer: entry[kCGWindowLayer as String] as? Int ?? 0,
                bounds: bounds
            )
            cgOrder.append(windowID)
        }

        // Front-to-back z-order, limited to the active Space. Windows the CG list
        // does not describe are dropped so every number here has a known owner.
        let spaceFiltered = NSWindow.windowNumbers(options: [.allApplications])?
            .map(\.intValue)
            .filter { infoByID[$0] != nil }

        let ordered: [Int]
        let isSpaceFiltered: Bool
        if let spaceFiltered, !spaceFiltered.isEmpty {
            ordered = spaceFiltered
            isSpaceFiltered = true
        } else {
            // The public z-ordered list was unavailable; fall back to the CG list,
            // which is not Space-filtered. Logged by the caller so a regression is
            // visible rather than silent.
            ordered = cgOrder
            isSpaceFiltered = false
        }

        return Snapshot(
            ordered: ordered,
            isSpaceFiltered: isSpaceFiltered,
            infoByID: infoByID,
            visible: Set(ordered)
        )
    }

    // MARK: - Targeted Probes

    // These are used while waiting for a triggered window to disappear. They are
    // deliberately narrow (one window server query, or one accessibility query)
    // because they run in a tight poll loop.

    func isWindowOnScreen(windowID: Int) -> Bool {
        let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []
        return list.contains { ($0[kCGWindowNumber as String] as? Int) == windowID }
    }

    func visibleLayer0WindowCount(ownerPID pid: pid_t) -> Int {
        let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements],
            kCGNullWindowID
        ) as? [[String: Any]] ?? []
        return list.reduce(into: 0) { count, entry in
            if (entry[kCGWindowOwnerPID as String] as? pid_t) == pid,
               (entry[kCGWindowLayer as String] as? Int) == 0 {
                count += 1
            }
        }
    }

    /// Whether the app's accessibility window list still contains a window at
    /// `bounds`, or nil when that list cannot be read.
    ///
    /// This is the earliest reliable "the window is closing" signal. Measured on
    /// macOS 27 for a Finder close: the accessibility list drops the window at
    /// ~281ms, while the window stays in the on-screen list until ~569ms (its
    /// alpha fades from ~339ms). Reading the earlier signal roughly halves the
    /// time before focus can move.
    func sourceAppHasWindow(ownerPID pid: pid_t, matching bounds: CGRect, tolerance: CGFloat = 2) -> Bool? {
        guard let windows = accessibilityWindows(ownerPID: pid) else { return nil }
        return windows.contains { window in
            guard let frame = AXGeometry.frame(of: window) else { return false }
            return abs(frame.minX - bounds.minX) <= tolerance &&
                abs(frame.minY - bounds.minY) <= tolerance &&
                abs(frame.width - bounds.width) <= tolerance &&
                abs(frame.height - bounds.height) <= tolerance
        }
    }

    /// The app's accessibility window count, or nil when it cannot be read.
    func sourceAppWindowCount(ownerPID pid: pid_t) -> Int? {
        accessibilityWindows(ownerPID: pid)?.count
    }

    func accessibilityWindows(ownerPID pid: pid_t) -> [AXUIElement]? {
        let appElement = AXUIElementCreateApplication(pid)
        guard let value = AXGeometry.attribute(of: appElement, key: kAXWindowsAttribute as CFString) else {
            return nil
        }
        return value as? [AXUIElement]
    }
}
