import AppKit

/// Coordinates the V4 event monitor and the focus recovery engine.
final class WindowManager {

    private let accessibilityHelper: AccessibilityHelper
    private let eventMonitor: FocusEventMonitor
    private let recoveryEngine: FocusRecoveryEngine
    private var isMonitoring = false

    init(accessibilityHelper: AccessibilityHelper) {
        self.accessibilityHelper = accessibilityHelper
        self.eventMonitor = FocusEventMonitor()
        self.recoveryEngine = FocusRecoveryEngine(accessibilityHelper: accessibilityHelper)

        self.eventMonitor.onFocusCheckNeeded = { [weak self] context in
            guard let self = self, self.isEnabled() else { return }
            self.recoveryEngine.performRecoveryCheck(context: context)
        }
    }

    func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true
        AppLogger.info("Starting")
        eventMonitor.startMonitoring()
    }

    func stopMonitoring() {
        guard isMonitoring else { return }
        isMonitoring = false
        eventMonitor.stopMonitoring()
    }

    private func isEnabled() -> Bool {
        UserDefaults.standard.bool(forKey: "isEnabled")
    }
}
