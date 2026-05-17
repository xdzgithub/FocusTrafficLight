//
//  WindowManager_v3.1.0.swift
//  FocusTrafficLight
//
//  Version: 3.1.0
//  Date: 2026-05-17
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
            self?.recoveryEngine.performRecoveryCheck()
        }
    }

    func startMonitoring() {
        guard !isMonitoring else { return }
        isMonitoring = true
        print("[FocusTrafficLight] Starting")
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
