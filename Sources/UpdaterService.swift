import AppKit
import Sparkle

/// Manual-only update checks.
///
/// The feed is a static `appcast.xml` on GitHub Releases, and Sparkle verifies
/// each archive against the EdDSA public key in Info.plist before installing it.
/// That signature is what makes an update trustworthy, not the URL: anyone who
/// reached the repository could replace the file, but only the holder of the
/// private key (in this Mac's keychain) can sign one that Sparkle will accept.
///
/// Nothing here runs on its own. `SUEnableAutomaticChecks` is false and the
/// scheduled interval is zero, so the app makes no network request until the
/// user picks "Check for Updates", and `automaticallyDownloadsUpdates` is off so
/// even then the install waits for an explicit confirmation.
final class UpdaterService: NSObject, SPUUpdaterDelegate {
    private var updater: SPUUpdater?

    /// The version shown in the menu, taken from the running bundle.
    static var shortVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "—"
    }

    func start() {
        let updater = SPUUpdater(
            hostBundle: .main,
            applicationBundle: .main,
            userDriver: SPUStandardUserDriver(hostBundle: .main, delegate: nil),
            delegate: self
        )
        updater.automaticallyChecksForUpdates = false
        updater.automaticallyDownloadsUpdates = false

        do {
            try updater.start()
            self.updater = updater
            AppLogger.notice("Updater ready — feed checks are manual only")
        } catch {
            // Not fatal: the rest of the app works without updating, so this is
            // logged rather than surfaced. A menu click with no updater still
            // tells the user why.
            AppLogger.notice("Updater unavailable: \(error.localizedDescription)")
        }
    }

    /// Called by the menu item. Asks Sparkle to check now and to show its own UI.
    /// Returns false when the updater never started, so the caller can say so
    /// instead of appearing to do nothing.
    @discardableResult
    func checkForUpdates() -> Bool {
        guard let updater else { return false }
        updater.checkForUpdates()
        return true
    }
}
