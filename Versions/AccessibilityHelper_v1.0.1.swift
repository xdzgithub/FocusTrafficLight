import AppKit
import ApplicationServices

final class AccessibilityHelper {

    nonisolated func checkAccessibilityPermission() -> Bool {
        let promptKey = unsafeBitCast(kAXTrustedCheckOptionPrompt, to: CFString.self)
        let options = [promptKey: false] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    nonisolated func requestAccessibilityPermission() -> Bool {
        let promptKey = unsafeBitCast(kAXTrustedCheckOptionPrompt, to: CFString.self)
        let options = [promptKey: true] as CFDictionary
        return AXIsProcessTrustedWithOptions(options)
    }

    func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
        NSWorkspace.shared.open(url)
    }
}
