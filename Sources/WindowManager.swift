//
//  WindowManager_v3.3.0.swift
//  FocusTrafficLight
//
//  Version: 3.3.5
//  Date: 2026-05-20
//
//  =============================================================================
//  CHANGELOG (v3.3.5) — Fix Ghost Window Guard-2 Block
//  =============================================================================
//
//  BUG FIX:
//    — Guard 2 (frontmostAppHasVisibleWindow) now filters out tiny windows
//      (<100×100px). Apps like 百度网盘 keep invisible helper windows that
//      caused Guard 2 to block recovery after the main window was minimized
//      or closed. This is a generic fix for any app with shadow/ghost windows.
//    — Guard block logs upgraded from debug to info level for Release builds.
//
//  =============================================================================
//  CHANGELOG (v3.3.4) — Remove App-Launch Focus Recovery
//  =============================================================================
//
//  BUG FIX:
//    — Removed performRecoveryCheck() from onAppLaunched entirely. App launch
//      recovery raced with cold-launch window creation (most visible with
//      System Settings), stealing focus back to the previous app. macOS
//      handles focus on app launch correctly on its own.
//    — Retained: isValidRecoveryTarget subrole relax, closeButton soft-log,
//      and diagnostic logging from v3.3.3.
//
//  =============================================================================
//  CHANGELOG (v3.3.3) — System Settings Focus Recovery Fix
//  =============================================================================
//
//  BUG FIX (v3.3.3):
//    — onAppLaunched deferred performRecoveryCheck() by 0.3s (later replaced
//      by v3.3.4's full removal).
//    — isValidRecoveryTarget relaxed: accepts AXDialog, AXFloatingWindow,
//      AXSystemDialog subroles (was AXStandardWindow only). CloseButton
//      attribute check changed from hard-reject to soft-log.
//    — Diagnostic logging added to FocusEventMonitor and FocusRecoveryEngine
//      for trigger tracing (subsystem: com.focustrafficlight.app).
//
//  =============================================================================
//  CHANGELOG (v3.3.0) — Removed App Termination Monitoring
//  =============================================================================
//
//  P2 OPTIMIZATION:
//    — Replaced all print() with structured os_log via AppLogger
//      · debug() stripped in Release builds (reduces console noise)
//      · info() always emitted for operational visibility
//    — Unified version: project.yml MARKETING_VERSION now 3.2.0 → 3.3.0
//
//  =============================================================================
//  PRIOR VERSION HISTORY
//  =============================================================================
//
//  v3.2.0 (2026-05-17) — P1 Architecture Refactor + Hidden Event Support
//  — Split monolithic WindowManager into FocusEventMonitor + FocusRecoveryEngine
//  — Added kAXApplicationHiddenNotification (Cmd+H) support
//
//  v3.0.0–v3.1.0 (2026-05-16) — State-Driven Focus Recovery + P0 Safety Fixes
//
//  =============================================================================
//  CHANGELOG (v3.1.0) — P1 Architecture Refactor + Hidden Event Support
//  =============================================================================
//
//  REFACTOR: Split monolithic WindowManager into three focused components:
//
//    — FocusEventMonitor: AXObserver lifecycle + event scheduling
//    — FocusRecoveryEngine: state-driven recovery decision logic
//    — WindowManager: lightweight coordinator wiring them together
//
//  This resolves the "single class with 659 lines" problem from the v3.0.0
//  review. Each component now has a single, well-defined responsibility.
//
//  NEW: Added kAXApplicationHiddenNotification support.
//    When user Cmd+H hides an app, the hidden app no longer holds focus.
//    The event monitor now triggers a recovery check in this scenario.
//
//  =============================================================================
//  PRIOR VERSION HISTORY
//  =============================================================================
//
//  v3.0.0 (2026-05-16) — State-Driven Focus Recovery Architecture
//  — Four-layer guard: Quick Look → Frontmost Windows → Focus Validity → Recovery
//  — Dual validation: isUsableFocusedWindow (permissive) + isValidRecoveryTarget (strict)
//  — CGWindow↔AXWindow Z-order matching via bounds+title
//  — Finder Quick Look CGWindow hard block
//  — App startup Open Panel / Save Panel guard (frontmostAppHasVisibleWindow)
//
//  =============================================================================

import AppKit

/// Lightweight coordinator that wires FocusEventMonitor and FocusRecoveryEngine.
///
/// Responsibilities:
///   — Owns the two subsystems
///   — Delegates app launch events to the monitor
///   — Bridges the monitor's event signal to the recovery engine
final class WindowManager {

    private let accessibilityHelper: AccessibilityHelper
    private let eventMonitor: FocusEventMonitor
    private let recoveryEngine: FocusRecoveryEngine
    private var isMonitoring = false

    init(accessibilityHelper: AccessibilityHelper) {
        self.accessibilityHelper = accessibilityHelper
        self.eventMonitor = FocusEventMonitor()
        self.recoveryEngine = FocusRecoveryEngine(accessibilityHelper: accessibilityHelper)

        self.eventMonitor.onFocusCheckNeeded = { [weak self] in
            guard let self = self, self.isEnabled() else { return }
            self.recoveryEngine.performRecoveryCheck()
        }

        self.eventMonitor.onAppLaunched = { [weak self] app in
            // App launch does not need focus recovery — macOS handles focus
            // correctly on its own. A recovery check here races with the new
            // app's window creation and may steal focus back to the previous app.
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
        return UserDefaults.standard.bool(forKey: "isEnabled")
    }
}
