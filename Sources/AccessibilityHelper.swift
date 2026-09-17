import AppKit
import ApplicationServices
import IOKit.hidsystem

final class AccessibilityHelper {

    nonisolated func checkAccessibilityPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): false] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    nonisolated func requestAccessibilityPermission() -> Bool {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    /// Input Monitoring gate for observing key events. Public API since 10.15
    /// (`IOKit/hidsystem/IOHIDLib.h`); reported rather than requested, so a
    /// denial shows up as a clear log line instead of a silently dead monitor.
    nonisolated func inputMonitoringStatus() -> String {
        switch IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) {
        case kIOHIDAccessTypeGranted: return "granted"
        case kIOHIDAccessTypeDenied: return "denied"
        default: return "not determined"
        }
    }

    /// Screen Recording is not required by this app: window ordering and bounds
    /// come from CGWindowList keys that stay readable without it. Logged anyway
    /// because a missing grant is the usual reason window *titles* read empty.
    nonisolated func screenRecordingGranted() -> Bool {
        CGPreflightScreenCaptureAccess()
    }

    func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }

    func openInputMonitoringSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent")!
        NSWorkspace.shared.open(url)
    }
}
