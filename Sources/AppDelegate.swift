import AppKit
import ServiceManagement

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var statusItem: NSStatusItem!
    private var windowManager: WindowManager!
    private var accessibilityHelper: AccessibilityHelper!
    private let updater = UpdaterService()

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
        updater.start()

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

        let enabledItem = NSMenuItem(title: Localized.string("menu.enable"), action: #selector(toggleEnabled(_:)), keyEquivalent: "")
        enabledItem.target = self
        enabledItem.state = isEnabled ? .on : .off
        menu.addItem(enabledItem)

        let launchAtLoginItem = NSMenuItem(title: Localized.string("menu.launchAtLogin"), action: #selector(toggleLaunchAtLogin(_:)), keyEquivalent: "")
        launchAtLoginItem.target = self
        launchAtLoginItem.state = isLaunchAtLoginEnabled() ? .on : .off
        menu.addItem(launchAtLoginItem)

        menu.addItem(NSMenuItem.separator())

        // One item, not two: the version is the context for the action, and
        // splitting it into a separate disabled row only took up a line.
        let checkForUpdatesItem = NSMenuItem(
            title: Localized.string("menu.checkForUpdates", UpdaterService.shortVersion),
            action: #selector(checkForUpdates(_:)),
            keyEquivalent: ""
        )
        checkForUpdatesItem.target = self
        menu.addItem(checkForUpdatesItem)

        let starItem = NSMenuItem(
            title: Localized.string("menu.star"),
            action: #selector(openGitHubRepository(_:)),
            keyEquivalent: ""
        )
        starItem.target = self
        menu.addItem(starItem)

        menu.addItem(NSMenuItem.separator())

        let quitItem = NSMenuItem(title: Localized.string("menu.quit"), action: #selector(quitApp(_:)), keyEquivalent: "q")
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func checkAccessibilityPermissions() {
        AppLogger.notice(
            "Permissions — accessibility=\(accessibilityHelper.checkAccessibilityPermission()) inputMonitoring=\(accessibilityHelper.inputMonitoringStatus()) screenRecording=\(accessibilityHelper.screenRecordingGranted())"
        )

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

    @objc private func checkForUpdates(_ sender: NSMenuItem) {
        AppLogger.notice("Check for Updates chosen by the user")

        guard updater.checkForUpdates() else {
            // The updater failed to start at launch, so there is nothing to ask.
            // Saying so beats a menu item that appears to do nothing.
            let alert = NSAlert()
            alert.messageText = Localized.string("alert.updateUnavailable.title")
            alert.informativeText = Localized.string("alert.updateUnavailable.message")
            alert.alertStyle = .warning
            alert.addButton(withTitle: Localized.string("alert.ok"))
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
            return
        }

        // A menu-bar app has no window of its own, so the update panel would
        // open behind whatever is frontmost without this.
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func openGitHubRepository(_ sender: NSMenuItem) {
        guard let url = URL(string: "https://github.com/xdzgithub/FocusTrafficLight") else { return }
        NSWorkspace.shared.open(url)
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
