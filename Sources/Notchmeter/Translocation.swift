import AppKit

/// A quarantined app launched from Downloads or straight from the DMG runs from a random read-only
/// `/private/var/folders/…/AppTranslocation/` path, where the login item registers the wrong path and Sparkle
/// cannot replace the bundle. Offered once at launch: copy to /Applications, relaunch from there, trash the original.
enum Translocation {
    static func isTranslocated(_ path: String) -> Bool {
        path.contains("/AppTranslocation/")
    }

    static func isInApplications(_ path: String, home: String = Paths.home.path) -> Bool {
        path.hasPrefix("/Applications/") || path.hasPrefix(home + "/Applications/")
    }

    /// Offer the move for a translocated bundle, or one outside the Applications folders that is not a build in the
    /// repository (`build/Notchmeter.app` is the developer's own copy).
    static func shouldOffer(bundlePath: String, home: String = Paths.home.path) -> Bool {
        guard bundlePath.hasSuffix(".app") else { return false }
        if isTranslocated(bundlePath) { return true }
        if isInApplications(bundlePath, home: home) { return false }
        return !bundlePath.contains("/build/") && !bundlePath.contains("/.build/")
    }

    static func describe(bundlePath: String) -> String {
        "bundle \(bundlePath.replacingOccurrences(of: Paths.home.path, with: "~")) translocated=\(isTranslocated(bundlePath)) inApplications=\(isInApplications(bundlePath))"
    }

    @MainActor
    static func offerMove(bundleURL: URL = Bundle.main.bundleURL) {
        let alert = NSAlert()
        alert.messageText = L("Move %@ to the Applications folder?", AppInfo.name)
        alert.informativeText = L("Running from here, Open at login and updates cannot work. The app is copied to /Applications, relaunched from there, and this copy is moved to the Trash.")
        alert.addButton(withTitle: L("Move to Applications"))
        alert.addButton(withTitle: L("Not now"))
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        let destination = URL(fileURLWithPath: "/Applications").appendingPathComponent(bundleURL.lastPathComponent)
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: destination.path) { try fm.trashItem(at: destination, resultingItemURL: nil) }
            try fm.copyItem(at: bundleURL, to: destination)
        } catch {
            let failure = NSAlert()
            failure.messageText = L("Could not move %@", AppInfo.name)
            failure.informativeText = error.localizedDescription
            failure.runModal()
            return
        }
        try? fm.trashItem(at: bundleURL, resultingItemURL: nil)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = ["-n", destination.path]
        try? process.run()
        NSApp.terminate(nil)
    }
}
