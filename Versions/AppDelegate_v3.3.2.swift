import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var windowManager: WindowManager!
    private var accessibilityHelper: AccessibilityHelper!

    private var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: "isEnabled") }
        set { UserDefaults.standard.set(newValue, forKey: "isEnabled") }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        UserDefaults.standard.register(defaults: ["isEnabled": true])

        accessibilityHelper = AccessibilityHelper()
        windowManager = WindowManager(accessibilityHelper: accessibilityHelper)

        setupStatusItem()
        checkAccessibilityPermissions()

        if isEnabled {
            windowManager.startMonitoring()
        }
    }

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)

        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "hand.tap.fill", accessibilityDescription: "FocusTrafficLight")
            button.image?.isTemplate = true
        }

        let menu = NSMenu()

        let enabledItem = NSMenuItem(title: "Enable Focus", action: #selector(toggleEnabled(_:)), keyEquivalent: "")
        enabledItem.target = self
        enabledItem.state = isEnabled ? .on : .off
        menu.addItem(enabledItem)

        let launchAtLoginItem = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        launchAtLoginItem.target = self
        launchAtLoginItem.state = isLaunchAtLoginEnabled() ? .on : .off
        menu.addItem(launchAtLoginItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: "Quit", action: #selector(quitApp(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func checkAccessibilityPermissions() {
        // Check if permission already granted
        if accessibilityHelper.checkAccessibilityPermission() {
            return
        }

        // Request permission - this shows the system permission dialog directly
        let granted = accessibilityHelper.requestAccessibilityPermission()

        if !granted {
            // User declined, open settings for manual grant
            accessibilityHelper.openAccessibilitySettings()
        }
    }

    @objc private func toggleEnabled(_ sender: NSMenuItem) {
        isEnabled.toggle()
        sender.state = isEnabled ? .on : .off

        if isEnabled {
            windowManager.startMonitoring()
        } else {
            windowManager.stopMonitoring()
        }
    }

    @objc private func toggleLaunchAtLogin(_ sender: NSMenuItem) {
        let newState = !isLaunchAtLoginEnabled()
        setLaunchAtLogin(enabled: newState)
        sender.state = newState ? .on : .off
    }

    @objc private func quitApp(_ sender: NSMenuItem) {
        NSApplication.shared.terminate(nil)
    }

    private func isLaunchAtLoginEnabled() -> Bool {
        return SMAppService.mainApp.status == .enabled
    }

    private func setLaunchAtLogin(enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            AppLogger.info("Failed to set launch at login: \(error)")
        }
    }
}
