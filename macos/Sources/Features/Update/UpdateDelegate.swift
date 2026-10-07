import Sparkle
import Cocoa

extension UpdateDriver: SPUUpdaterDelegate {
    func feedURLString(for updater: SPUUpdater) -> String? {
        // Use this bundle's configured feed, including for manual menu checks.
        // Config channels and old Sparkle defaults must not switch a fork to upstream.
        // Sparkle treats nil as permission to fall back to old defaults/Info.plist.
        // An empty override is invalid and cannot select a different feed.
        (try? UpdateConfiguration(bundle: updater.hostBundle).feedURL.absoluteString) ?? ""
    }

    func updater(_ updater: SPUUpdater, mayPerform updateCheck: SPUUpdateCheck) throws {
        // Covers direct/background Sparkle checks as well as the controller entry points.
        _ = try UpdateConfiguration(bundle: updater.hostBundle)
    }

    /// Called when an update is scheduled to install silently,
    /// which occurs when `auto-update = download`.
    ///
    /// When `auto-update = check`, Sparkle will call the corresponding
    /// delegate method on the responsible driver instead.
    func updater(_ updater: SPUUpdater, willInstallUpdateOnQuit item: SUAppcastItem, immediateInstallationBlock immediateInstallHandler: @escaping () -> Void) -> Bool {
        viewModel.state = .installing(.init(
            appcastItem: item,
            retryTerminatingApplication: immediateInstallHandler
        ))
        AppDelegate.logger.info("Version: \(item.displayVersionString) installed silently, waiting for relaunch...")
        // Even when hasUnobtrusiveTarget is false, we don't show the alert immediately.
        // We wait until the user manually checks for updates or relaunches.
        return true
    }
}
