import AppKit
import ServiceManagement

/// Keeps one Lasso: the copy in Applications. An update replaces the copy that's running, and the
/// login item opens whichever copy registered it, so a copy run from elsewhere (an Xcode build folder,
/// Downloads, the disk image) could take the update and the login item, and the next login or Xcode
/// build brought back an older Lasso. Settings, keys, chats and packages aren't in the app, so which
/// copy runs never changes them.
@MainActor
enum AppLocation {
    static let releaseID = "com.cjcarito.Lasso"
    static let applications = URL(fileURLWithPath: "/Applications/Lasso.app")

    static func isInApplications(_ url: URL = Bundle.main.bundleURL) -> Bool {
        let path = url.resolvingSymlinksInPath().path
        return path.hasPrefix("/Applications/")
            || path.hasPrefix(FileManager.default.homeDirectoryForCurrentUser.appending(path: "Applications").path + "/")
    }

    static func version(_ url: URL) -> String? {
        Bundle(url: url)?.infoDictionary?["CFBundleShortVersionString"] as? String
    }

    /// At launch (the real Lasso only; Xcode builds are "Lasso Dev" and never get here).
    static func check() {
        guard Bundle.main.bundleIdentifier == releaseID,
              ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil else { return }
        if isInApplications() {
            repointLoginItem()
        } else {
            offerApplications()
        }
    }

    /// Launch at login opens the copy that registered it: make that this one, once per version.
    static func repointLoginItem() {
        let key = "app.loginItemPointsAt"
        let here = "\(Bundle.main.bundleURL.path)|\(Bundle.main.lassoVersion)"
        guard LoginItem.isEnabled, UserDefaults.standard.string(forKey: key) != here else { return }
        try? SMAppService.mainApp.unregister()
        do {
            try SMAppService.mainApp.register()
            UserDefaults.standard.set(here, forKey: key)
            Log.app.notice("login item now opens \(Bundle.main.bundleURL.path, privacy: .public)")
        } catch {
            Log.app.error("login item: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Running from outside Applications: say so once per copy and version, and offer the fix.
    static func offerApplications() {
        let key = "app.locationAsked"
        let here = "\(Bundle.main.bundleURL.path)|\(Bundle.main.lassoVersion)"
        guard UserDefaults.standard.string(forKey: key) != here else { return }
        UserDefaults.standard.set(here, forKey: key)

        let installed = FileManager.default.fileExists(atPath: applications.path) ? version(applications) : nil
        let mine = Bundle.main.lassoVersion
        let alert = NSAlert()
        alert.messageText = "Lasso is running from outside Applications"
        let place = (Bundle.main.bundleURL.deletingLastPathComponent().path as NSString).abbreviatingWithTildeInPath
        alert.informativeText = "This copy is in \(place). Updates go to the copy that's running, and starting at login "
            + "opens whichever copy set it up, so two copies drift apart and an older Lasso can come back.\n\n"
            + "Your settings, keys, chats and packages stay the same whichever copy you use."
        enum Choice { case useInstalled, replace, move }
        var choices: [Choice] = []
        if let installed {
            if PackageValidator.isNewer(mine, than: installed) {
                alert.addButton(withTitle: "Replace the One in Applications"); choices.append(.replace)
            } else {
                alert.addButton(withTitle: "Use the One in Applications (\(installed))"); choices.append(.useInstalled)
            }
        } else {
            alert.addButton(withTitle: "Move to Applications"); choices.append(.move)
        }
        alert.addButton(withTitle: "Keep Using This Copy")
        NSApp.activate(ignoringOtherApps: true)
        let response = alert.runModal()
        let index = response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue
        guard choices.indices.contains(index) else { return }
        do {
            if choices[index] != .useInstalled { try copySelfToApplications() }
            relaunch(applications)
        } catch {
            let failed = NSAlert()
            failed.messageText = "Lasso couldn't copy itself to Applications"
            failed.informativeText = "\(error.localizedDescription)\n\nDrag Lasso from the disk image or this folder into Applications instead."
            failed.runModal()
        }
    }

    /// Copies this Lasso into Applications, replacing the copy there (the app only: nothing else).
    static func copySelfToApplications() throws {
        let fm = FileManager.default
        let staging = applications.deletingLastPathComponent().appending(path: ".Lasso-\(UUID().uuidString).app")
        try fm.copyItem(at: Bundle.main.bundleURL, to: staging)
        if fm.fileExists(atPath: applications.path) {
            _ = try fm.replaceItemAt(applications, withItemAt: staging)
        } else {
            try fm.moveItem(at: staging, to: applications)
        }
    }

    /// Opens `url` and quits this copy, so only one Lasso runs.
    static func relaunch(_ url: URL) {
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in
            Task { @MainActor in NSApp.terminate(nil) }
        }
    }
}
